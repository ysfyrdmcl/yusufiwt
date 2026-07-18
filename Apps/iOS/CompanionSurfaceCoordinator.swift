@preconcurrency import ActivityKit
import AgentCompanion
import AgentDomain
import Foundation
import UIKit
@preconcurrency import WatchConnectivity
import WidgetKit

@MainActor
final class CompanionSurfaceCoordinator {
    private let appGroupID: String
    private let defaults: UserDefaults?
    private let watch = PhoneWatchConnectivityCoordinator()
    private var pushTokenTask: Task<Void, Never>?

    var decisionHandler: ((WatchDecisionMessage) async -> Void)? {
        didSet { watch.decisionHandler = decisionHandler }
    }

    var liveActivityTokenHandler: ((UUID, Data) async -> Void)?

    init(appGroupID: String) {
        self.appGroupID = appGroupID
        defaults = UserDefaults(suiteName: appGroupID)
        watch.activate()
    }

    deinit {
        pushTokenTask?.cancel()
    }

    func publish(sessions: [CompanionSessionSummary], inbox: [CompanionInboxItem], now: Date) async {
        let snapshot = CompanionSurfaceSnapshot(sessions: sessions, inbox: inbox, generatedAt: now)
        if let data = try? snapshot.encoded() {
            defaults?.set(data, forKey: CompanionSurfaceSnapshot.storageKey)
            WidgetCenter.shared.reloadAllTimelines()
            watch.send(snapshot)
        }
        await reconcileSelectedActivity(with: sessions, now: now)
    }

    func select(_ session: CompanionSessionSummary, now: Date) async {
        defaults?.set(session.id.rawValue.uuidString.lowercased(), forKey: Self.selectedSessionKey)
        await endActivities(except: session.id.rawValue, dismissalPolicy: .immediate)
        if let existing = Activity<AgentActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == session.id.rawValue
        }) {
            await update(existing, session: session, now: now)
            observePushToken(for: existing)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = AgentActivityContentState(state: session.state, updatedAt: now)
        do {
            let activity = try Activity.request(
                attributes: AgentActivityAttributes(session: session),
                content: ActivityContent(state: state, staleDate: state.staleAt),
                pushType: .token
            )
            observePushToken(for: activity)
        } catch {
            defaults?.removeObject(forKey: Self.selectedSessionKey)
        }
    }

    func clearSelection() async {
        defaults?.removeObject(forKey: Self.selectedSessionKey)
        pushTokenTask?.cancel()
        pushTokenTask = nil
        await endActivities(except: nil, dismissalPolicy: .immediate)
    }

    func selectedSessionID() -> SessionID? {
        guard let raw = defaults?.string(forKey: Self.selectedSessionKey),
              let id = UUID(uuidString: raw)
        else { return nil }
        return SessionID(id)
    }

    private func reconcileSelectedActivity(with sessions: [CompanionSessionSummary], now: Date) async {
        guard let selected = selectedSessionID(),
              let session = sessions.first(where: { $0.id == selected }),
              now.timeIntervalSince(session.updatedAt) < CompanionSurfaceLimits.staleInterval,
              session.state != .stale
        else {
            await clearSelection()
            return
        }
        await endActivities(except: selected.rawValue, dismissalPolicy: .immediate)
        guard let activity = Activity<AgentActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == selected.rawValue
        }) else { return }
        await update(activity, session: session, now: now)
        observePushToken(for: activity)
    }

    private func update(
        _ activity: Activity<AgentActivityAttributes>,
        session: CompanionSessionSummary,
        now: Date
    ) async {
        let state = AgentActivityContentState(state: session.state, updatedAt: session.updatedAt)
        let content = ActivityContent(state: state, staleDate: state.staleAt)
        if state.isFinal {
            await activity.end(content, dismissalPolicy: .after(now.addingTimeInterval(60)))
            defaults?.removeObject(forKey: Self.selectedSessionKey)
            pushTokenTask?.cancel()
            pushTokenTask = nil
        } else {
            await activity.update(content)
        }
    }

    private func endActivities(
        except selectedID: UUID?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        for activity in Activity<AgentActivityAttributes>.activities where activity.attributes.sessionID != selectedID {
            await activity.end(nil, dismissalPolicy: dismissalPolicy)
        }
    }

    private func observePushToken(for activity: Activity<AgentActivityAttributes>) {
        pushTokenTask?.cancel()
        pushTokenTask = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.liveActivityTokenHandler?(activity.attributes.sessionID, token)
            }
        }
    }

    private static let selectedSessionKey = "selected-live-activity-session-v1"
}

@MainActor
final class PhoneWatchConnectivityCoordinator: NSObject, WCSessionDelegate {
    var decisionHandler: ((WatchDecisionMessage) async -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ snapshot: CompanionSurfaceSnapshot) {
        guard WCSession.isSupported(), let data = try? snapshot.encoded() else { return }
        try? WCSession.default.updateApplicationContext([WatchMessageCodec.snapshotKey: data])
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let decision = try? WatchMessageCodec.decodeDecision(message) {
            Task { @MainActor [weak self] in
                await self?.decisionHandler?(decision)
            }
            return
        }
        guard let raw = message["open_iPhone"] as? String else { return }
        Task { @MainActor in
            guard let url = URL(string: raw), CompanionDeepLink(url: url) != nil else { return }
            await UIApplication.shared.open(url)
        }
    }
}
