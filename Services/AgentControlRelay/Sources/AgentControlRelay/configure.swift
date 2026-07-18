import FluentPostgresDriver
import FluentSQLiteDriver
import Redis
import Vapor

public func configure(_ application: Application) async throws {
    let config = try RelayConfiguration.fromEnvironment(application.environment)
    application.relayConfiguration = config
    application.accessTokenService = AccessTokenService(secret: config.tokenSecret)
    application.appleIdentityVerifier = AppleIdentityTokenVerifier(audiences: config.allowedAppleAudiences)
    application.storage[RateLimiterKey.self] = SlidingWindowRateLimiter()
    application.storage[PushTokenVaultKey.self] = PushTokenVault(secret: config.tokenSecret)
    application.storage[SocketHubKey.self] = RelaySocketHub()
    application.pushProvider = DisabledPushProvider()
    application.liveActivityPushProvider = DisabledLiveActivityPushProvider()
    let memoryEphemeral = MemoryPresenceProvider()
    application.presenceProvider = memoryEphemeral
    application.transientEnvelopeQueue = memoryEphemeral

    let values = ProcessInfo.processInfo.environment
    try await configurePushProvider(on: application, values: values)
    try configureDatabase(on: application, values: values)
    try configureRedis(on: application, values: values, config: config)

    application.migrations.add(CreateRelaySchema())
    application.migrations.add(CreateLiveActivityTokenSchema())
    try await application.autoMigrate()

    application.middleware.use(RateLimitMiddleware())
    application.middleware.use(MutationIdempotencyMiddleware(store: MutationIdempotencyStore()))
    try application.register(collection: AuthController())
    let protected = application.grouped(DeviceAuthenticator(), AuthenticatedDevice.guardMiddleware())
    try protected.grouped("v1").register(collection: DevicePairingController())
    try protected.grouped("v1").register(collection: EnvelopeController())

    application.get("v1", "health") { request async throws -> HealthResponse in
        _ = try await UserModel.query(on: request.db).count()
        return .init(status: "ok", database: "ok", redis: values["REDIS_URL"] == nil ? "disabled" : "configured")
    }
    application.get("v1", "ready") { request async throws -> HTTPStatus in
        _ = try await UserModel.query(on: request.db).count()
        return .ok
    }
    configureWebSocket(on: application)
    application.lifecycle.use(EnvelopeRetentionLifecycle(hours: config.dataRetentionHours))
}

private func configureDatabase(on application: Application, values: [String: String]) throws {
    if values["RELAY_USE_IN_MEMORY_DB"] == "1" || application.environment == .testing {
        application.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        guard let databaseURL = values["DATABASE_URL"], let postgres = URL(string: databaseURL) else {
            throw Abort(.internalServerError, reason: "Missing DATABASE_URL")
        }
        try application.databases.use(.postgres(url: postgres), as: .psql)
    }
}

private func configureRedis(on application: Application, values: [String: String], config: RelayConfiguration) throws {
    if let redisURL = values["REDIS_URL"] {
        application.redis.configuration = try RedisConfiguration(url: redisURL)
        let redisEphemeral = RedisEphemeralProvider(
            client: application.redis,
            presenceTTL: Int(values["PRESENCE_TTL_SECONDS"] ?? "90") ?? 90,
            envelopeTTL: Int(config.envelopeTTL)
        )
        application.presenceProvider = redisEphemeral
        application.transientEnvelopeQueue = redisEphemeral
    }
}

private func configurePushProvider(on application: Application, values: [String: String]) async throws {
    guard let keyID = values["APNS_KEY_ID"], keyID != "example-required",
          let teamID = values["APNS_TEAM_ID"], teamID != "example-required",
          let encodedKey = values["APNS_PRIVATE_KEY_B64"], encodedKey != "example-required",
          let keyData = Data(base64Encoded: encodedKey),
          let keyPEM = String(data: keyData, encoding: .utf8),
          let topic = values["APNS_TOPIC"]
    else { return }
    let bearer = try await APNSJWTBearerTokenProvider.make(keyID: keyID, teamID: teamID, privateKeyPEM: keyPEM)
    application.pushProvider = HTTPAPNSProvider(
        client: application.client, bearerTokens: bearer, topic: topic,
        production: values["APNS_ENVIRONMENT"] == "production"
    )
    if let liveActivityTopic = values["APNS_LIVE_ACTIVITY_TOPIC"], !liveActivityTopic.isEmpty {
        guard liveActivityTopic == "\(topic).push-type.liveactivity" else {
            throw Abort(.internalServerError, reason: "APNS_LIVE_ACTIVITY_TOPIC must match APNS_TOPIC")
        }
        application.liveActivityPushProvider = HTTPAPNSLiveActivityProvider(
            client: application.client, bearerTokens: bearer, topic: liveActivityTopic,
            production: values["APNS_ENVIRONMENT"] == "production"
        )
    }
}

private func configureWebSocket(on application: Application) {
    application.webSocket("v1", "ws") { request, socket in
        Task {
            guard let token = request.query[String.self, at: "access_token"],
                  let identity = try? application.accessTokenService.verify(token),
                  let device = try? await DeviceModel.find(identity.deviceID, on: request.db),
                  device.revokedAt == nil
            else { try? await socket.close(code: .policyViolation); return }
            await application.socketHub.connect(deviceID: identity.deviceID, socket: socket)
            await application.presenceProvider.markOnline(deviceID: identity.deviceID)
            socket.onClose.whenComplete { _ in
                Task {
                    await application.socketHub.disconnect(deviceID: identity.deviceID)
                    await application.presenceProvider.markOffline(deviceID: identity.deviceID)
                }
            }
            try? await socket.send("{\"state\":\"connected\"}")
        }
    }
}

struct EnvelopeRetentionLifecycle: LifecycleHandler {
    let hours: Int
    func didBoot(_ application: Application) throws {
        application.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .minutes(5), delay: .hours(1)) { _ in
            Task {
                try? await EnvelopeModel.query(on: application.db)
                    .group(.or) { group in
                        group.filter(\.$ackedAt != nil)
                            .filter(\.$expiresAt < Date().addingTimeInterval(TimeInterval(-hours * 3600)))
                    }.delete()
                try? await LiveActivityTokenModel.query(on: application.db)
                    .filter(\.$expiresAt < Date())
                    .delete()
            }
        }
    }
}
