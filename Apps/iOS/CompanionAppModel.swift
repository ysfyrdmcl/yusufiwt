import AgentCompanion
import AgentDomain
import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI
import UIKit
@preconcurrency import UserNotifications

// This file intentionally keeps the observable model and its same-file persistence extension together.
// swiftlint:disable file_length

enum CompanionRuntimeConfiguration {
    static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "AgentControlAppGroup") as? String
        ?? "group.com.yusuf.agentcontrol"
    static let keychainAccessGroup = Bundle.main.object(forInfoDictionaryKey: "AgentControlKeychainGroup") as? String
    static let secureStateAccount = "ios-secure-state-v1"

    static var relayBaseURL: URL {
        let fallback = URL(string: "https://relay.agentcontrol.app")!
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "AgentControlRelayBaseURL") as? String,
              let value = URL(string: raw)
        else { return fallback }
        guard value.scheme == "https" || value.host == "127.0.0.1" else { return fallback }
        return value
    }
}

struct CompanionLocalState: Codable, Sendable {
    var inbox: [CompanionInboxItem] = []
    var sessions: [CompanionSessionSummary] = []
    var outbox: [CompanionPendingDecision] = []
    var cursor: UInt64 = 0
    var outgoingSequence: UInt64 = 0
    var privacy: CompanionNotificationPrivacy = .projectOnly
    var lastSyncAt: Date?
}

struct PendingPairingConfirmation: Identifiable {
    let id: UUID
    let payload: PairingQRCodePayload
    let phoneKeys: PairingKeyMaterial
    let fingerprint: String
}

@MainActor
final class CompanionAppModel: ObservableObject {
    @Published private(set) var signedIn = false
    @Published private(set) var paired = false
    @Published private(set) var isSyncing = false
    @Published private(set) var inbox: [CompanionInboxItem] = []
    @Published private(set) var sessions: [CompanionSessionSummary] = []
    @Published private(set) var outbox: [CompanionPendingDecision] = []
    @Published private(set) var devices: [CompanionDeviceRecord] = []
    @Published var privacy: CompanionNotificationPrivacy = .projectOnly
    @Published var selectedInboxID: UUID?
    @Published var selectedSessionID: SessionID?
    @Published var pendingPairing: PendingPairingConfirmation?
    @Published private(set) var pinnedSessionID: SessionID?
    @Published var message: String?

    private var localState = CompanionLocalState()
    private var secureState: CompanionSecureState?
    private var relay: CompanionRelayClient?
    private var outboxActor = CompanionDecisionOutbox()
    private var pendingIdentity: CompanionIdentity?
    private var appleNonce: String?
    private var pushToken: Data?
    private let surfaces: CompanionSurfaceCoordinator

    private let keyStore = CompanionKeyStore(
        accessGroup: CompanionRuntimeConfiguration.keychainAccessGroup
    )

    init() {
        surfaces = CompanionSurfaceCoordinator(appGroupID: CompanionRuntimeConfiguration.appGroupID)
        surfaces.decisionHandler = { [weak self] decision in
            await self?.handleWatchDecision(decision)
        }
        surfaces.liveActivityTokenHandler = { [weak self] sessionID, token in
            await self?.registerLiveActivityToken(sessionID: sessionID, token: token)
        }
        pinnedSessionID = surfaces.selectedSessionID()
    }

    var macDisplayName: String {
        devices.first(where: { $0.role == .localMac })?.displayName ?? String(localized: "status.mac")
    }

    var lastSyncAt: Date? {
        localState.lastSyncAt
    }

    var history: [CompanionPendingDecision] {
        outbox.filter(\.state.isFinal).sorted { $0.updatedAt > $1.updatedAt }
    }

    func start() async {
        loadLocalState()
        do {
            if let data = try keyStore.load(account: CompanionRuntimeConfiguration.secureStateAccount) {
                secureState = try CompanionCoding.makeDecoder().decode(CompanionSecureState.self, from: data)
                signedIn = true
                paired = secureState?.macDeviceID != nil
                if let secureState {
                    relay = CompanionRelayClient(baseURL: secureState.relayBaseURL, accessToken: secureState.accessToken)
                }
            }
        } catch {
            message = String(localized: "error.secureState")
        }
        outboxActor = CompanionDecisionOutbox(restored: localState.outbox)
        await requestNotificationPermission()
        if signedIn {
            await refresh()
        }
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let raw = randomNonce()
        let hash = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        appleNonce = hash
        request.nonce = hash
        request.requestedScopes = [.fullName]
        pendingIdentity = CompanionIdentity(role: .iPhone)
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, any Error>) async {
        do {
            guard case let .success(authorization) = result,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let identity = pendingIdentity
            else { throw CompanionUIError.invalidAppleCredential }
            let client = CompanionRelayClient(baseURL: CompanionRuntimeConfiguration.relayBaseURL)
            let displayName = UIDevice.current.name
            let tokens = try await client.authenticate(
                .init(
                    identityToken: token, nonce: appleNonce, deviceID: identity.deviceID.rawValue,
                    role: .iPhone, displayName: displayName,
                    agreementPublicKey: identity.agreementPublicKey,
                    signingPublicKey: identity.signingPublicKey
                )
            )
            let state = CompanionSecureState(
                identity: identity, relayBaseURL: CompanionRuntimeConfiguration.relayBaseURL, tokens: tokens
            )
            secureState = state
            relay = client
            try persistSecureState()
            signedIn = true
            pendingIdentity = nil
            if let pushToken {
                await registerPushToken(pushToken)
            }
            await loadDevices()
        } catch {
            message = error.localizedDescription
            pendingIdentity = nil
        }
    }

    func scanPairingCode(_ value: String) async {
        do {
            guard signedIn, let relay else { throw CompanionUIError.signInRequired }
            let payload = try PairingQRCodeCodec.decode(value, now: Date())
            let phoneKeys = PairingKeyMaterial()
            let completed = try await relay.completePairing(
                sessionID: payload.sessionID, phoneEphemeralPublicKey: phoneKeys.publicKey
            )
            guard completed.macDeviceID == payload.macDeviceID.rawValue,
                  completed.macEphemeralPublicKey == payload.macEphemeralPublicKey
            else { throw CompanionCryptoError.invalidPairingPayload }
            let derived = try phoneKeys.derive(
                peerPublicKey: payload.macEphemeralPublicKey, sessionID: payload.sessionID
            )
            pendingPairing = .init(
                id: payload.sessionID, payload: payload, phoneKeys: phoneKeys,
                fingerprint: derived.fingerprint
            )
        } catch {
            message = error.localizedDescription
        }
    }

    func confirmPairing() async {
        do {
            guard let pendingPairing, var secureState else { throw CompanionUIError.pairingUnavailable }
            await loadDevices()
            guard let mac = devices.first(where: {
                $0.id == pendingPairing.payload.macDeviceID.rawValue && $0.role == .localMac && $0.revokedAt == nil
            }) else { throw CompanionUIError.macUnavailable }
            secureState.macDeviceID = DeviceID(mac.id)
            secureState.macAgreementPublicKey = mac.agreementPublicKey
            secureState.macSigningPublicKey = mac.signingPublicKey
            secureState.fingerprint = pendingPairing.fingerprint
            self.secureState = secureState
            try persistSecureState()
            paired = true
            self.pendingPairing = nil
            await refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func cancelPairing() {
        pendingPairing = nil
    }
}

extension CompanionAppModel {
    func refresh() async {
        guard signedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await refreshTokenIfNeeded()
            guard let relay else { return }
            if paired {
                let result = try await relay.pending(after: localState.cursor)
                for envelope in result.envelopes {
                    try await ingest(envelope)
                }
                localState.cursor = result.cursor
                localState.lastSyncAt = Date()
                await flushOutbox()
            }
            await loadDevices()
            saveLocalState()
        } catch {
            message = String(localized: "status.offline")
        }
    }

    func decide(
        item: CompanionInboxItem,
        outcome: CompanionRequestedOutcome,
        answer: String? = nil,
        evidence: CompanionDecisionEvidence
    ) async {
        do {
            try CompanionDecisionPolicy().authorize(
                outcome: outcome, for: item, evidence: evidence, answer: answer, now: Date()
            )
            let payload = CompanionDecisionPayload(
                requestID: item.id, requestVersion: item.requestVersion,
                requestedOutcome: outcome, answer: answer, decidedAt: Date(),
                strongAuthentication: evidence.strongAuthentication
            )
            _ = await outboxActor.enqueue(payload, now: Date())
            await synchronizeOutboxSnapshot()
            saveLocalState()
            await flushOutbox()
        } catch {
            message = error.localizedDescription
        }
    }

    func approveHighRisk(_ item: CompanionInboxItem) async {
        do {
            let authenticated = try await BiometricAuthenticator.authenticate(
                reason: String(localized: "biometric.reason")
            )
            guard authenticated else { throw CompanionUIError.authenticationCancelled }
            await decide(
                item: item, outcome: .approve,
                evidence: .init(
                    surface: .applicationDetail, strongAuthentication: true, holdCompleted: true
                )
            )
        } catch {
            message = String(localized: "biometric.failed")
        }
    }

    func handle(_ action: DeferredNotificationAction) async {
        guard let data = action.itemData,
              let item = try? CompanionCoding.makeDecoder().decode(CompanionInboxItem.self, from: data)
        else {
            if action.identifier == CompanionNotificationActions.review {
                await refresh()
            }
            return
        }
        selectedInboxID = item.id
        switch action.identifier {
        case CompanionNotificationActions.approve:
            await decide(item: item, outcome: .approve, evidence: .init(surface: .notificationAction))
        case CompanionNotificationActions.deny:
            await decide(item: item, outcome: .deny, evidence: .init(surface: .notificationAction))
        case CompanionNotificationActions.answer:
            await decide(
                item: item, outcome: .answer, answer: action.answer,
                evidence: .init(surface: .notificationAction)
            )
        default:
            break
        }
    }

    func open(_ url: URL) {
        guard let link = CompanionDeepLink(url: url) else { return }
        switch link {
        case let .inbox(id): selectedInboxID = id
        case let .session(id): selectedSessionID = id
        case .pairing: break
        }
    }

    func setPrivacy(_ value: CompanionNotificationPrivacy) {
        privacy = value
        localState.privacy = value
        UserDefaults(suiteName: CompanionRuntimeConfiguration.appGroupID)?.set(value.rawValue, forKey: "notification-privacy")
        saveLocalState()
    }

    func registerPushToken(_ token: Data) async {
        pushToken = token
        guard let relay else { return }
        let value = token.map { String(format: "%02x", $0) }.joined()
        do {
            #if DEBUG
                let environment = "sandbox"
            #else
                let environment = "production"
            #endif
            try await relay.registerPushToken(id: UUID(), token: value, environment: environment)
        } catch {
            // Pending fetch remains authoritative; retry on the next app launch/sync.
        }
    }

    func toggleLiveActivity(for session: CompanionSessionSummary) async {
        if pinnedSessionID == session.id {
            await surfaces.clearSelection()
            pinnedSessionID = nil
        } else {
            await surfaces.select(session, now: Date())
            pinnedSessionID = surfaces.selectedSessionID()
        }
    }

    func revoke(_ device: CompanionDeviceRecord) async {
        do {
            try await relay?.revokeDevice(device.id)
            if device.id == secureState?.identityDeviceID.rawValue {
                try keyStore.delete(account: CompanionRuntimeConfiguration.secureStateAccount)
                secureState = nil
                signedIn = false
                paired = false
                relay = nil
            }
            await loadDevices()
        } catch {
            message = error.localizedDescription
        }
    }
}

private extension CompanionAppModel {
    func ingest(_ envelope: SealedRelayEnvelope) async throws {
        guard let secureState,
              let macSigningKey = secureState.macSigningPublicKey,
              let macAgreementKey = secureState.macAgreementPublicKey,
              let relay
        else { throw CompanionUIError.pairingUnavailable }
        let identity = try secureState.identity()
        switch envelope.kind {
        case .approvalRequest, .questionRequest:
            let item: CompanionInboxItem = try identity.open(
                envelope, senderSigningPublicKey: macSigningKey,
                senderAgreementPublicKey: macAgreementKey, now: Date()
            )
            await ingestInboxItem(item)
        case .sessionStatus:
            let session: CompanionSessionSummary = try identity.open(
                envelope, senderSigningPublicKey: macSigningKey,
                senderAgreementPublicKey: macAgreementKey, now: Date()
            )
            if let index = localState.sessions.firstIndex(where: { $0.id == session.id }) {
                localState.sessions[index] = session
            } else {
                localState.sessions.append(session)
            }
        case .providerAcknowledgment:
            let acknowledgment: ProviderAcknowledgmentPayload = try identity.open(
                envelope, senderSigningPublicKey: macSigningKey,
                senderAgreementPublicKey: macAgreementKey, now: Date()
            )
            await outboxActor.markAcknowledged(acknowledgment, at: acknowledgment.acknowledgedAt)
        default:
            break
        }
        try await relay.acknowledge(envelope.envelopeID)
        await synchronizePublishedState()
    }

    func ingestInboxItem(_ item: CompanionInboxItem) async {
        guard let index = localState.inbox.firstIndex(where: { $0.id == item.id }) else {
            localState.inbox.append(item)
            return
        }
        let previous = localState.inbox[index]
        if item.requestVersion > previous.requestVersion {
            let superseded = await outboxActor.snapshot().filter {
                $0.requestID == item.id && $0.requestVersion < item.requestVersion && !$0.state.isFinal
            }
            for decision in superseded {
                await outboxActor.markTerminal(
                    decision.id, state: .superseded,
                    reason: "request-version-superseded", at: Date()
                )
            }
        }
        if item.requestVersion >= previous.requestVersion {
            localState.inbox[index] = item
        }
    }

    func flushOutbox() async {
        guard let secureState, let macID = secureState.macDeviceID,
              let macAgreementKey = secureState.macAgreementPublicKey, let relay
        else { return }
        do {
            let identity = try secureState.identity()
            let expiries = Dictionary(uniqueKeysWithValues: localState.inbox.map { ($0.id, $0.expiresAt) })
            await outboxActor.expire(at: Date(), requestExpiries: expiries)
            for pending in await outboxActor.snapshot() where pending.state == .queued || pending.state == .sending {
                localState.outgoingSequence += 1
                await outboxActor.markSending(pending.id, at: Date())
                let envelope = try identity.seal(
                    pending.payload, kind: .companionDecision, recipient: macID,
                    recipientAgreementPublicKey: macAgreementKey,
                    sequence: localState.outgoingSequence, createdAt: Date(),
                    expiresAt: Date().addingTimeInterval(300)
                )
                do {
                    try await relay.submit(envelope, idempotencyKey: pending.id)
                    await outboxActor.markServerAccepted(
                        pending.id, envelopeID: envelope.envelopeID, at: Date()
                    )
                } catch {
                    // Leave as sending so a reconnect retries with the same logical outbox ID.
                    break
                }
            }
            await synchronizeOutboxSnapshot()
            saveLocalState()
        } catch {
            message = String(localized: "status.offline")
        }
    }

    func refreshTokenIfNeeded() async throws {
        guard var secureState, secureState.accessTokenExpiresAt <= Date().addingTimeInterval(60), let relay else { return }
        let tokens = try await relay.refresh(secureState.refreshToken)
        secureState.accessToken = tokens.accessToken
        secureState.accessTokenExpiresAt = tokens.accessTokenExpiresAt
        secureState.refreshToken = tokens.refreshToken
        self.secureState = secureState
        try persistSecureState()
    }

    func loadDevices() async {
        guard let relay else { return }
        if let value = try? await relay.devices() {
            devices = value.filter { $0.revokedAt == nil }
        }
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func synchronizePublishedState() async {
        inbox = localState.inbox.sorted { $0.createdAt > $1.createdAt }
        sessions = localState.sessions.sorted { $0.updatedAt > $1.updatedAt }
        await synchronizeOutboxSnapshot()
        await surfaces.publish(sessions: sessions, inbox: inbox, now: Date())
        pinnedSessionID = surfaces.selectedSessionID()
    }

    func synchronizeOutboxSnapshot() async {
        localState.outbox = await outboxActor.snapshot()
        outbox = localState.outbox.sorted { $0.updatedAt > $1.updatedAt }
    }

    func persistSecureState() throws {
        guard let secureState else { return }
        try keyStore.save(
            CompanionCoding.makeEncoder().encode(secureState),
            account: CompanionRuntimeConfiguration.secureStateAccount
        )
    }

    func loadLocalState() {
        guard let url = localStateURL(), let data = try? Data(contentsOf: url),
              let value = try? CompanionCoding.makeDecoder().decode(CompanionLocalState.self, from: data)
        else { return }
        localState = value
        inbox = value.inbox
        sessions = value.sessions
        outbox = value.outbox
        privacy = value.privacy
        Task { await surfaces.publish(sessions: sessions, inbox: inbox, now: Date()) }
    }

    func saveLocalState() {
        guard let url = localStateURL(), let data = try? CompanionCoding.makeEncoder().encode(localState) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func localStateURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CompanionRuntimeConfiguration.appGroupID
        )?.appendingPathComponent("companion-state-v1.json", isDirectory: false)
    }

    func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    func registerLiveActivityToken(sessionID: UUID, token: Data) async {
        guard let relay else { return }
        do {
            #if DEBUG
                let environment = "sandbox"
            #else
                let environment = "production"
            #endif
            try await relay.registerLiveActivityToken(
                id: UUID(), sessionID: sessionID,
                token: token.map { String(format: "%02x", $0) }.joined(),
                environment: environment,
                expiresAt: Date().addingTimeInterval((8 * 60 * 60) - 300)
            )
        } catch {
            // Local ActivityKit updates remain available; token registration retries on the next state update.
        }
    }

    func handleWatchDecision(_ decision: WatchDecisionMessage) async {
        guard abs(decision.createdAt.timeIntervalSinceNow) <= 60,
              !outbox.contains(where: {
                  $0.requestID == decision.requestID && $0.requestVersion == decision.requestVersion
              })
        else { return }
        guard let item = inbox.first(where: {
            $0.id == decision.requestID && $0.requestVersion == decision.requestVersion
        }) else { return }
        let card = WatchRequestCard(item: item)
        guard WatchDecisionPolicy.disposition(outcome: decision.outcome, card: card, now: Date()) == .allowed else {
            return
        }
        await decide(
            item: item, outcome: decision.outcome,
            evidence: .init(surface: .watch, strongAuthentication: false, holdCompleted: false)
        )
    }
}

enum CompanionUIError: LocalizedError {
    case invalidAppleCredential
    case signInRequired
    case pairingUnavailable
    case macUnavailable
    case authenticationCancelled

    var errorDescription: String? {
        switch self {
        case .invalidAppleCredential: String(localized: "error.appleCredential")
        case .signInRequired: String(localized: "error.signInRequired")
        case .pairingUnavailable: String(localized: "error.pairingUnavailable")
        case .macUnavailable: String(localized: "error.macUnavailable")
        case .authenticationCancelled: String(localized: "error.authenticationCancelled")
        }
    }
}

enum BiometricAuthenticator {
    static func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "common.cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? CompanionUIError.authenticationCancelled
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
    }
}
