import AgentCompanion
import AgentDomain
import SwiftUI
@preconcurrency import WatchConnectivity

@main
struct AgentControlWatchApp: App {
    @StateObject private var model = WatchCompanionModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchDashboard(model: model)
            }
            .task { model.activate() }
        }
    }
}

private struct WatchDashboard: View {
    @ObservedObject var model: WatchCompanionModel

    var body: some View {
        List {
            if let request = model.snapshot?.watch.highestPriorityRequest {
                Section(String(localized: "Needs attention")) {
                    NavigationLink {
                        WatchRequestDetail(model: model, card: request)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.title).font(.headline).lineLimit(2)
                            Text(request.projectName).font(.caption).foregroundStyle(.secondary)
                            Text(request.risk.rawValue.capitalized)
                                .font(.caption2.bold()).foregroundStyle(riskColor(request.risk))
                        }
                    }
                }
            }
            Section(String(localized: "Sessions")) {
                if let sessions = model.snapshot?.watch.sessions, !sessions.isEmpty {
                    ForEach(sessions) { session in
                        HStack {
                            Image(systemName: symbol(session.state)).foregroundStyle(color(session.state))
                            VStack(alignment: .leading) {
                                Text(session.projectName).lineLimit(1)
                                Text(session.state.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text(String(localized: "No active sessions")).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("AgentControl")
        .overlay(alignment: .bottom) {
            if let status = model.status {
                Text(status).font(.caption2).padding(5).background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}

private struct WatchRequestDetail: View {
    @ObservedObject var model: WatchCompanionModel
    let card: WatchRequestCard

    var body: some View {
        List {
            Section {
                Text(card.title)
                LabeledContent(String(localized: "Project"), value: card.projectName)
                LabeledContent(String(localized: "Risk"), value: card.risk.rawValue.capitalized)
            }
            Section {
                if WatchDecisionPolicy.disposition(outcome: .approve, card: card, now: .now) == .allowed {
                    Button(String(localized: "Approve")) { model.send(.approve, card: card) }
                        .tint(.green)
                } else {
                    Button(String(localized: "Review on iPhone")) { model.openOnIPhone(card) }
                }
                Button(String(localized: "Deny"), role: .destructive) { model.send(.deny, card: card) }
            }
        }
        .navigationTitle(card.agentName)
    }
}

@MainActor
private final class WatchCompanionModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: CompanionSurfaceSnapshot?
    @Published private(set) var status: String?

    func activate() {
        guard WCSession.isSupported() else {
            status = String(localized: "iPhone connection unavailable")
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
        ingest(WCSession.default.receivedApplicationContext)
    }

    func send(_ outcome: CompanionRequestedOutcome, card: WatchRequestCard) {
        guard WatchDecisionPolicy.disposition(outcome: outcome, card: card, now: .now) == .allowed else {
            openOnIPhone(card)
            return
        }
        let decision = WatchDecisionMessage(
            requestID: card.id, requestVersion: card.requestVersion,
            outcome: outcome, createdAt: .now
        )
        guard WCSession.default.isReachable,
              let message = try? WatchMessageCodec.encodeDecision(decision)
        else {
            status = String(localized: "Open iPhone to continue")
            return
        }
        WCSession.default.sendMessage(message, replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.status = String(localized: "Open iPhone to continue") }
        }
        status = String(localized: "Sent to iPhone")
    }

    func openOnIPhone(_ card: WatchRequestCard) {
        let url = "agentcontrol://inbox/\(card.id.uuidString.lowercased())"
        guard WCSession.default.isReachable else {
            status = String(localized: "Open AgentControl on iPhone")
            return
        }
        WCSession.default.sendMessage(["open_iPhone": url], replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.status = String(localized: "Open AgentControl on iPhone") }
        }
        status = String(localized: "Continue on iPhone")
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            if let error {
                self?.status = error.localizedDescription
            } else {
                self?.ingest(session.receivedApplicationContext)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor [weak self] in self?.ingest(applicationContext) }
    }

    private func ingest(_ context: [String: Any]) {
        guard let data = context[WatchMessageCodec.snapshotKey] as? Data,
              let value = try? CompanionSurfaceSnapshot.decode(data)
        else { return }
        snapshot = value
        status = nil
    }
}

private func riskColor(_ risk: RiskLevel) -> Color {
    switch risk {
    case .low: .green
    case .medium: .orange
    case .high, .critical: .red
    }
}

private func symbol(_ state: SessionState) -> String {
    switch state {
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    case .waitingApproval, .waitingInput: "exclamationmark.bubble.fill"
    default: "waveform.path.ecg"
    }
}

private func color(_ state: SessionState) -> Color {
    switch state {
    case .completed: .green
    case .failed: .red
    case .waitingApproval, .waitingInput: .orange
    default: .blue
    }
}
