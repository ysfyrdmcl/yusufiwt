import Fluent

struct CreateRelaySchema: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserModel.schema)
            .id().field("apple_subject_hash", .string, .required).field("created_at", .datetime)
            .unique(on: "apple_subject_hash").create()
        try await database.schema(DeviceModel.schema)
            .id().field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("role", .string, .required).field("display_name", .string, .required)
            .field("agreement_public_key", .data, .required).field("signing_public_key", .data, .required)
            .field("revoked_at", .datetime).field("created_at", .datetime)
            .create()
        try await database.schema(RefreshTokenModel.schema)
            .id().field("device_id", .uuid, .required, .references(DeviceModel.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required).field("expires_at", .datetime, .required).field("revoked_at", .datetime)
            .unique(on: "token_hash").create()
        try await database.schema(PairingSessionModel.schema)
            .id().field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("mac_device_id", .uuid, .required, .references(DeviceModel.schema, "id", onDelete: .cascade))
            .field("mac_ephemeral_public_key", .data, .required).field("phone_device_id", .uuid)
            .field("phone_ephemeral_public_key", .data).field("expires_at", .datetime, .required).field("completed_at", .datetime)
            .create()
        try await database.schema(EnvelopeModel.schema)
            .id().field("sender_device_id", .uuid, .required, .references(DeviceModel.schema, "id", onDelete: .cascade))
            .field("recipient_device_id", .uuid, .required, .references(DeviceModel.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required).field("created_at", .datetime, .required).field("expires_at", .datetime, .required)
            .field("sequence", .int64, .required).field("key_id", .uuid, .required)
            .field("ciphertext", .data, .required).field("signature", .data, .required).field("acked_at", .datetime)
            .unique(on: "sender_device_id", "sequence").create()
        try await database.schema(PushTokenModel.schema)
            .id().field("device_id", .uuid, .required, .references(DeviceModel.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required).field("token_ciphertext", .data, .required)
            .field("environment", .string, .required).field("updated_at", .datetime)
            .unique(on: "token_hash").create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PushTokenModel.schema).delete()
        try await database.schema(EnvelopeModel.schema).delete()
        try await database.schema(PairingSessionModel.schema).delete()
        try await database.schema(RefreshTokenModel.schema).delete()
        try await database.schema(DeviceModel.schema).delete()
        try await database.schema(UserModel.schema).delete()
    }
}

struct CreateLiveActivityTokenSchema: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(LiveActivityTokenModel.schema)
            .id()
            .field(
                "device_id", .uuid, .required,
                .references(DeviceModel.schema, "id", onDelete: .cascade)
            )
            .field("session_id", .uuid, .required)
            .field("token_hash", .string, .required)
            .field("token_ciphertext", .data, .required)
            .field("environment", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("updated_at", .datetime)
            .unique(on: "device_id", "session_id")
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(LiveActivityTokenModel.schema).delete()
    }
}
