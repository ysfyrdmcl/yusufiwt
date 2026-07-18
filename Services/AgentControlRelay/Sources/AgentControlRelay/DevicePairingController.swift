import Fluent
import Vapor

struct DevicePairingController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("macs", "register", use: registerMac)
        routes.get("devices", use: listDevices)
        routes.delete("devices", ":id", use: revokeDevice)
        routes.post("pairing", "sessions", use: createPairing)
        routes.post("pairing", "sessions", ":id", "complete", use: completePairing)
    }

    private func registerMac(request: Request) async throws -> DeviceResponse {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard auth.role == .localMac else { throw Abort(.forbidden) }
        let input = try request.content.decode(RegisterMacRequest.self)
        guard input.deviceID == auth.deviceID else { throw Abort(.forbidden) }
        let model = try await DeviceModel.find(auth.deviceID, on: request.db) ?? { throw Abort(.notFound) }()
        model.displayName = input.displayName
        model.agreementPublicKey = input.agreementPublicKey
        model.signingPublicKey = input.signingPublicKey
        try await model.update(on: request.db)
        return try response(model)
    }

    private func listDevices(request: Request) async throws -> [DeviceResponse] {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        return try await DeviceModel.query(on: request.db).filter(\.$userID == auth.userID).all().map(response)
    }

    private func revokeDevice(request: Request) async throws -> HTTPStatus {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard let id = request.parameters.get("id", as: UUID.self),
              let device = try await DeviceModel.find(id, on: request.db), device.userID == auth.userID
        else { throw Abort(.notFound) }
        device.revokedAt = Date()
        try await device.update(on: request.db)
        try await RefreshTokenModel.query(on: request.db).filter(\.$deviceID == id).set(\.$revokedAt, to: Date()).update()
        try await EnvelopeModel.query(on: request.db).group(.or) { group in
            group.filter(\.$senderDeviceID == id).filter(\.$recipientDeviceID == id)
        }.delete()
        return .noContent
    }

    private func createPairing(request: Request) async throws -> PairingSessionResponse {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard auth.role == .localMac else { throw Abort(.forbidden) }
        let input = try request.content.decode(CreatePairingRequest.self)
        guard input.macEphemeralPublicKey.count == 32 else { throw Abort(.badRequest) }
        let model = PairingSessionModel(
            userID: auth.userID, macDeviceID: auth.deviceID,
            macEphemeralPublicKey: input.macEphemeralPublicKey,
            expiresAt: Date().addingTimeInterval(request.application.relayConfiguration.pairingTTL)
        )
        try await model.save(on: request.db)
        return try pairingResponse(model)
    }

    private func completePairing(request: Request) async throws -> PairingSessionResponse {
        let auth = try request.auth.require(AuthenticatedDevice.self)
        guard auth.role != .localMac, let id = request.parameters.get("id", as: UUID.self),
              let model = try await PairingSessionModel.find(id, on: request.db),
              model.userID == auth.userID, model.expiresAt > Date(), model.completedAt == nil
        else { throw Abort(.gone, reason: "Pairing session expired or unavailable") }
        let input = try request.content.decode(CompletePairingRequest.self)
        guard input.phoneEphemeralPublicKey.count == 32 else { throw Abort(.badRequest) }
        model.phoneDeviceID = auth.deviceID
        model.phoneEphemeralPublicKey = input.phoneEphemeralPublicKey
        model.completedAt = Date()
        try await model.update(on: request.db)
        return try pairingResponse(model)
    }

    private func response(_ model: DeviceModel) throws -> DeviceResponse {
        guard let role = ServerDeviceRole(rawValue: model.role) else {
            throw Abort(.internalServerError, reason: "Invalid persisted device role")
        }
        return try DeviceResponse(
            id: model.requireID(), role: role, displayName: model.displayName,
            agreementPublicKey: model.agreementPublicKey, signingPublicKey: model.signingPublicKey, revokedAt: model.revokedAt
        )
    }

    private func pairingResponse(_ model: PairingSessionModel) throws -> PairingSessionResponse {
        try .init(
            id: model.requireID(), macDeviceID: model.macDeviceID,
            macEphemeralPublicKey: model.macEphemeralPublicKey, phoneDeviceID: model.phoneDeviceID,
            phoneEphemeralPublicKey: model.phoneEphemeralPublicKey, expiresAt: model.expiresAt
        )
    }
}
