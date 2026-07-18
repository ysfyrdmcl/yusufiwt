import AgentCompanion
import Foundation
@preconcurrency import UserNotifications

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private let completionLock = NSLock()
    private var completed = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? .init()
        bestAttemptContent = content
        applyGenericFallback(to: content)
        Task { await decryptAndRender(request: request, content: content) }
    }

    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func decryptAndRender(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent
    ) async {
        do {
            guard let envelopeText = request.content.userInfo["envelope_id"] as? String,
                  let envelopeID = UUID(uuidString: envelopeText)
            else { throw NotificationServiceError.invalidHint }
            let keyStore = CompanionKeyStore(accessGroup: Self.keychainAccessGroup)
            guard let stateData = try keyStore.load(account: "ios-secure-state-v1") else {
                throw NotificationServiceError.missingIdentity
            }
            var state = try CompanionCoding.makeDecoder().decode(CompanionSecureState.self, from: stateData)
            let relay = CompanionRelayClient(baseURL: state.relayBaseURL, accessToken: state.accessToken)
            if state.accessTokenExpiresAt <= Date().addingTimeInterval(30) {
                let tokens = try await relay.refresh(state.refreshToken)
                state.accessToken = tokens.accessToken
                state.accessTokenExpiresAt = tokens.accessTokenExpiresAt
                state.refreshToken = tokens.refreshToken
                try keyStore.save(
                    CompanionCoding.makeEncoder().encode(state), account: "ios-secure-state-v1"
                )
            }
            guard let macSigningKey = state.macSigningPublicKey,
                  let macAgreementKey = state.macAgreementPublicKey
            else { throw NotificationServiceError.missingIdentity }
            let result = try await relay.pending(after: 0)
            guard let envelope = result.envelopes.first(where: { $0.envelopeID == envelopeID }),
                  envelope.kind == .approvalRequest || envelope.kind == .questionRequest
            else { throw NotificationServiceError.envelopeUnavailable }
            let item: CompanionInboxItem = try state.identity().open(
                envelope,
                senderSigningPublicKey: macSigningKey,
                senderAgreementPublicKey: macAgreementKey,
                now: Date()
            )
            let privacyRaw = UserDefaults(suiteName: Self.appGroupID)?.string(forKey: "notification-privacy")
            let privacy = CompanionNotificationPrivacy(rawValue: privacyRaw ?? "") ?? .projectOnly
            let presentation = CompanionNotificationRenderer.render(item, privacy: privacy)
            content.title = presentation.title
            content.body = presentation.body
            content.categoryIdentifier = presentation.categoryIdentifier
            content.threadIdentifier = item.sessionID.description
            content.targetContentIdentifier = item.id.uuidString.lowercased()
            content.userInfo["companion_item"] = try CompanionCoding.makeEncoder().encode(item).base64EncodedString()
            content.userInfo["deep_link"] = "agentcontrol://inbox/\(item.id.uuidString.lowercased())"
            // The extension renders only. The app durably ingests the item before acknowledging it,
            // so dismissing a notification can never make an inbox item disappear.
        } catch {
            applyGenericFallback(to: content)
        }
        finish()
    }

    private func applyGenericFallback(to content: UNMutableNotificationContent) {
        let fallback = CompanionNotificationRenderer.genericFallback
        content.title = fallback.title
        content.body = fallback.body
        content.categoryIdentifier = fallback.categoryIdentifier
    }

    private func finish() {
        completionLock.lock()
        defer { completionLock.unlock() }
        guard !completed, let contentHandler, let bestAttemptContent else { return }
        completed = true
        contentHandler(bestAttemptContent)
    }

    private static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "AgentControlAppGroup") as? String
        ?? "group.com.yusuf.agentcontrol"
    private static let keychainAccessGroup = Bundle.main.object(
        forInfoDictionaryKey: "AgentControlKeychainGroup"
    ) as? String
}

private enum NotificationServiceError: Error {
    case invalidHint
    case missingIdentity
    case envelopeUnavailable
}
