import CryptoKit
import Foundation

/// Encrypts fields classified as sensitive before SQLite receives them.
public protocol SensitiveFieldCipher: Sendable {
    func encrypt(_ plaintext: Data, context: Data) throws -> Data
    func decrypt(_ ciphertext: Data, context: Data) throws -> Data
}

/// Production-safe default that refuses sensitive persistence until a key is supplied.
public struct UnavailableSensitiveFieldCipher: SensitiveFieldCipher {
    public init() {}

    public func encrypt(_: Data, context _: Data) throws -> Data {
        throw PersistenceError.encryptionUnavailable
    }

    public func decrypt(_: Data, context _: Data) throws -> Data {
        throw PersistenceError.encryptionUnavailable
    }
}

/// AES-GCM field encryption. The key must be sourced from Keychain by the composition root.
public struct AESGCMFieldCipher: SensitiveFieldCipher {
    private let key: SymmetricKey

    public init(keyData: Data) throws {
        guard [16, 24, 32].contains(keyData.count) else {
            throw PersistenceError.invalidStoredValue("AES key length")
        }
        key = SymmetricKey(data: keyData)
    }

    public func encrypt(_ plaintext: Data, context: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: context)
        guard let combined = sealed.combined else { throw PersistenceError.encryptionUnavailable }
        return combined
    }

    public func decrypt(_ ciphertext: Data, context: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: context)
    }
}
