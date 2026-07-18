import Crypto
import Fluent
import Vapor

struct EnvelopeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("envelopes", use: submit)
        routes.get("envelopes", "pending", use: pending)
        routes.post("envelopes", ":id", "ack", use: acknowledge)
        routes.post("push", "tokens", use: registerPushToken)
        routes.delete("push", "tokens", ":id", use: deletePushToken)
        routes.post("live-activities", "tokens", use: registerLiveActivityToken)
        routes.post("live-activities", "update", use: updateLiveActivity)
    }

    private func submit(request: Request) async throws -> EnvelopeAcceptedResponse {
        guard !request.application.emergencyDisablePolicy.envelopeSubmission else {
            throw Abort(.serviceUnavailable, reason: "Envelope submission is temporarily disabled")
        }
        let auth = try request.auth.require(AuthenticatedDevice.self)
        let input = try request.content.decode(RelayEnvelopeDTO.self)
        let config = request.application.relayConfiguration
        guard input.envelopeVersion == 1, input.senderDeviceID == auth.deviceID,
              input.ciphertext.count <= config.maxEnvelopeBytes, input.signature.count == 64,
              input.expiresAt > Date(), input.expiresAt <= input.createdAt.addingTimeInterval(config.envelopeTTL)
        else { throw Abort(.badRequest, reason: "Invalid envelope metadata") }
        guard directionAllowed(role: auth.role, kind: input.kind) else { throw Abort(.forbidden) }
        if let existing = try await EnvelopeModel.find(input.envelopeID, on: request.db) {
            guard existing.senderDeviceID == auth.deviceID else { throw Abort(.conflict) }
            return .init(envelopeID: input.envelopeID, state: "serverAccepted")
        }
        guard let sender = try await DeviceModel.find(auth.deviceID, on: request.db),
              let recipient = try await DeviceModel.find(input.recipientDeviceID, on: request.db),
              recipient.userID == auth.userID, recipient.revokedAt == nil
        else { throw Abort(.notFound, reason: "Recipient is not an active paired device") }
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: sender.signingPublicKey)
        guard signingKey.isValidSignature(input.signature, for: input.signingBytes) else {
            throw Abort(.unprocessableEntity, reason: "Envelope signature is invalid")
        }
        let latest = try await EnvelopeModel.query(on: request.db)
            .filter(\.$senderDeviceID == auth.deviceID).sort(\.$sequence, .descending).first()
        if let latest {
            guard input.sequence > UInt64(bitPattern: latest.sequence) else {
                throw Abort(.conflict, reason: "Envelope sequence was replayed")
            }
        }
        let count = try await EnvelopeModel.query(on: request.db)
            .filter(\.$recipientDeviceID == input.recipientDeviceID).filter(\.$ackedAt == nil)
            .filter(\.$expiresAt > Date()).count()
        guard count < config.maxPendingPerDevice else { throw Abort(.tooManyRequests) }
        try await EnvelopeModel(input).create(on: request.db)
        await request.application.transientEnvelopeQueue.enqueue(
            deviceID: input.recipientDeviceID, envelopeID: input.envelopeID
        )
        await request.application.socketHub.notify(deviceID: input.recipientDeviceID, envelopeID: input.envelopeID)
        try await sendPushHint(for: input, recipient: recipient, request: request)
        return .init(envelopeID: input.envelopeID, state: "serverAccepted")
    }

    private func pending(request: Request) async throws -> PendingEnvelopeResponse {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        let cursor = request.query[UInt64.self, at: "after"] ?? 0
        let models = try await EnvelopeModel.query(on: request.db)
            .filter(\.$recipientDeviceID == auth.deviceID).filter(\.$ackedAt == nil)
            .filter(\.$expiresAt > Date()).sort(\.$sequence, .ascending).all()
        let values = try models.map { try $0.response() }.filter { $0.sequence > cursor }
        return .init(envelopes: values, cursor: values.last?.sequence ?? cursor)
    }

    private func acknowledge(request: Request) async throws -> HTTPStatus {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard let id = request.parameters.get("id", as: UUID.self),
              let model = try await EnvelopeModel.find(id, on: request.db), model.recipientDeviceID == auth.deviceID
        else { throw Abort(.notFound) }
        model.ackedAt = Date()
        try await model.update(on: request.db)
        return .noContent
    }

    private func registerPushToken(request: Request) async throws -> HTTPStatus {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard auth.role != .localMac else { throw Abort(.forbidden) }
        let input = try request.content.decode(PushTokenRequest.self)
        guard input.token.count <= 512, ["sandbox", "production"].contains(input.environment) else { throw Abort(.badRequest) }
        let hash = SecretHash.make(input.token, pepper: request.application.relayConfiguration.tokenHashPepper)
        let model = try await PushTokenModel.find(input.id, on: request.db)
            ?? PushTokenModel(
                id: input.id, deviceID: auth.deviceID, tokenHash: hash,
                tokenCiphertext: request.application.pushTokenVault.seal(input.token), environment: input.environment
            )
        guard model.deviceID == auth.deviceID else { throw Abort(.forbidden) }
        model.tokenHash = hash
        model.tokenCiphertext = try request.application.pushTokenVault.seal(input.token)
        model.environment = input.environment
        try await model.save(on: request.db)
        return .accepted
    }

    private func deletePushToken(request: Request) async throws -> HTTPStatus {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard let id = request.parameters.get("id", as: UUID.self),
              let model = try await PushTokenModel.find(id, on: request.db), model.deviceID == auth.deviceID
        else { throw Abort(.notFound) }
        try await model.delete(on: request.db)
        return .noContent
    }

    private func registerLiveActivityToken(request: Request) async throws -> HTTPStatus {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard auth.role == .iPhone else { throw Abort(.forbidden) }
        let input = try request.content.decode(LiveActivityTokenRequest.self)
        let now = Date()
        guard input.token.count <= 512,
              ["sandbox", "production"].contains(input.environment),
              input.expiresAt > now,
              input.expiresAt <= now.addingTimeInterval(8 * 60 * 60)
        else { throw Abort(.badRequest) }
        let hash = SecretHash.make(input.token, pepper: request.application.relayConfiguration.tokenHashPepper)
        let model = try await LiveActivityTokenModel.query(on: request.db)
            .filter(\.$deviceID == auth.deviceID)
            .filter(\.$sessionID == input.sessionID)
            .first()
            ?? LiveActivityTokenModel(
                id: input.id, deviceID: auth.deviceID, sessionID: input.sessionID,
                tokenHash: hash,
                tokenCiphertext: request.application.pushTokenVault.seal(input.token),
                environment: input.environment, expiresAt: input.expiresAt
            )
        guard model.deviceID == auth.deviceID else { throw Abort(.forbidden) }
        model.tokenHash = hash
        model.tokenCiphertext = try request.application.pushTokenVault.seal(input.token)
        model.environment = input.environment
        model.expiresAt = input.expiresAt
        try await model.save(on: request.db)
        return .accepted
    }

    private func updateLiveActivity(request: Request) async throws -> HTTPStatus {
        guard !request.application.emergencyDisablePolicy.liveActivities else {
            throw Abort(.serviceUnavailable, reason: "Live Activities are temporarily disabled")
        }
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard auth.role == .localMac else { throw Abort(.forbidden) }
        let input = try request.content.decode(LiveActivityUpdateRequest.self)
        let allowedStates: Set = [
            "discovered", "starting", "thinking", "running", "executing",
            "waitingApproval", "waitingInput", "paused", "completed", "failed",
            "cancelled", "disconnected", "stale"
        ]
        let now = Date()
        guard allowedStates.contains(input.state),
              abs(input.updatedAt.timeIntervalSince(now)) <= 5 * 60,
              input.staleAt > input.updatedAt,
              input.staleAt <= input.updatedAt.addingTimeInterval(30 * 60),
              let recipient = try await DeviceModel.find(input.recipientDeviceID, on: request.db),
              recipient.userID == auth.userID,
              recipient.role == ServerDeviceRole.iPhone.rawValue,
              recipient.revokedAt == nil
        else { throw Abort(.badRequest) }
        guard let model = try await LiveActivityTokenModel.query(on: request.db)
            .filter(\.$deviceID == input.recipientDeviceID)
            .filter(\.$sessionID == input.sessionID)
            .filter(\.$expiresAt > now)
            .first()
        else { throw Abort(.notFound) }
        let token = try request.application.pushTokenVault.open(model.tokenCiphertext)
        let result = await request.application.liveActivityPushProvider.sendLiveActivityUpdate(input, to: token)
        await request.application.operationalMetrics.recordAPNS(result, channel: .liveActivity)
        switch result {
        case .accepted:
            return .accepted
        case .invalidToken:
            try await model.delete(on: request.db)
            throw Abort(.gone)
        case .retryable:
            throw Abort(.serviceUnavailable)
        case let .permanentFailure(reason):
            throw Abort(.badGateway, reason: reason)
        }
    }

    private func directionAllowed(role: ServerDeviceRole, kind: ServerEnvelopeKind) -> Bool {
        switch role {
        case .localMac:
            kind != .companionDecision
        case .iPhone, .watch:
            kind == .companionDecision || kind == .pairingConfirmation || kind == .keyRotation
        }
    }

    private func sendPushHint(for envelope: RelayEnvelopeDTO, recipient: DeviceModel, request: Request) async throws {
        guard recipient.role != ServerDeviceRole.localMac.rawValue,
              !request.application.emergencyDisablePolicy.apns
        else { return }
        for model in try await PushTokenModel.query(on: request.db).filter(\.$deviceID == envelope.recipientDeviceID).all() {
            let token = try request.application.pushTokenVault.open(model.tokenCiphertext)
            let result = await request.application.pushProvider.sendEnvelopeHint(
                envelopeID: envelope.envelopeID, category: envelope.kind.rawValue, to: token
            )
            await request.application.operationalMetrics.recordAPNS(result, channel: .notification)
            if result == .invalidToken {
                try await model.delete(on: request.db)
            }
        }
    }
}

final class SocketBox: @unchecked Sendable {
    let socket: WebSocket
    init(_ socket: WebSocket) {
        self.socket = socket
    }
}

actor RelaySocketHub {
    private var sockets: [UUID: SocketBox] = [:]
    func connect(deviceID: UUID, socket: WebSocket) {
        sockets[deviceID] = SocketBox(socket)
    }

    func disconnect(deviceID: UUID, close: Bool = false) async {
        let box = sockets.removeValue(forKey: deviceID)
        if close, let box {
            try? await box.socket.close(code: .normalClosure)
        }
    }

    func notify(deviceID: UUID, envelopeID: UUID) async {
        guard let box = sockets[deviceID] else { return }
        try? await box.socket.send("{\"envelope_id\":\"\(envelopeID.uuidString.lowercased())\"}")
    }
}

struct SocketHubKey: StorageKey { typealias Value = RelaySocketHub }
extension Application {
    var socketHub: RelaySocketHub {
        guard let value = storage[SocketHubKey.self] else {
            preconditionFailure("Socket hub was not installed")
        }
        return value
    }
}
