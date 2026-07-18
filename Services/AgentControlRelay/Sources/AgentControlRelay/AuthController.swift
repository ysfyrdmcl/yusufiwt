import Fluent
import Vapor

struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("v1", "auth")
        auth.post("apple", use: apple)
        auth.post("refresh", use: refresh)
    }

    private func apple(request: Request) async throws -> TokenResponse {
        let input = try request.content.decode(AppleAuthenticationRequest.self)
        guard input.displayName.count <= 100,
              input.agreementPublicKey.count == 32, input.signingPublicKey.count == 32
        else { throw Abort(.badRequest) }
        let subject = try await request.application.appleIdentityVerifier.verify(
            identityToken: input.identityToken, nonce: input.nonce, client: request.client
        )
        let subjectHash = SecretHash.make(subject, pepper: request.application.relayConfiguration.tokenHashPepper)
        let user: UserModel
        if let existing = try await UserModel.query(on: request.db).filter(\.$appleSubjectHash == subjectHash).first() {
            user = existing
        } else {
            user = UserModel(appleSubjectHash: subjectHash)
            try await user.save(on: request.db)
        }
        let userID = try user.requireID()
        if input.role == .localMac {
            let otherMac = try await DeviceModel.query(on: request.db)
                .filter(\.$userID == userID).filter(\.$role == ServerDeviceRole.localMac.rawValue)
                .filter(\.$revokedAt == nil).first()
            if let otherMac, try otherMac.requireID() != input.deviceID {
                throw Abort(.conflict, reason: "This account already has its single local Mac authority")
            }
        }
        let device = try await DeviceModel.find(input.deviceID, on: request.db)
            ?? DeviceModel(
                id: input.deviceID, userID: userID, role: input.role, displayName: input.displayName,
                agreementPublicKey: input.agreementPublicKey, signingPublicKey: input.signingPublicKey
            )
        guard device.userID == userID, device.revokedAt == nil else { throw Abort(.forbidden) }
        let rotatesKeys = device.agreementPublicKey != input.agreementPublicKey
            || device.signingPublicKey != input.signingPublicKey
        device.displayName = input.displayName
        device.agreementPublicKey = input.agreementPublicKey
        device.signingPublicKey = input.signingPublicKey
        try await device.save(on: request.db)
        if rotatesKeys {
            // Re-authentication with the account credential is the key-rotation
            // ceremony. Retire every refresh token tied to the old device keys.
            try await RefreshTokenModel.query(on: request.db)
                .filter(\.$deviceID == input.deviceID)
                .filter(\.$revokedAt == nil)
                .set(\.$revokedAt, to: Date())
                .update()
        }
        return try await issueTokens(
            for: .init(userID: userID, deviceID: input.deviceID, role: input.role), request: request
        )
    }

    private func refresh(request: Request) async throws -> TokenResponse {
        let input = try request.content.decode(RefreshRequest.self)
        let hash = SecretHash.make(input.refreshToken, pepper: request.application.relayConfiguration.tokenHashPepper)
        guard let stored = try await RefreshTokenModel.query(on: request.db).filter(\.$tokenHash == hash).first(),
              stored.revokedAt == nil, stored.expiresAt > Date(),
              let device = try await DeviceModel.find(stored.deviceID, on: request.db), device.revokedAt == nil,
              let role = ServerDeviceRole(rawValue: device.role)
        else { throw Abort(.unauthorized) }
        stored.revokedAt = Date()
        try await stored.update(on: request.db)
        return try await issueTokens(
            for: .init(userID: device.userID, deviceID: device.requireID(), role: role), request: request
        )
    }

    private func issueTokens(for identity: AuthenticatedDevice, request: Request) async throws -> TokenResponse {
        let now = Date()
        let accessExpiry = now.addingTimeInterval(request.application.relayConfiguration.accessTokenTTL)
        let access = try request.application.accessTokenService.issue(for: identity, expiresAt: accessExpiry)
        let refresh = randomToken()
        try await RefreshTokenModel(
            deviceID: identity.deviceID,
            tokenHash: SecretHash.make(refresh, pepper: request.application.relayConfiguration.tokenHashPepper),
            expiresAt: now.addingTimeInterval(request.application.relayConfiguration.refreshTokenTTL)
        ).save(on: request.db)
        return .init(accessToken: access, accessTokenExpiresAt: accessExpiry, refreshToken: refresh)
    }
}
