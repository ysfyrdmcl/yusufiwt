#if os(macOS)
    import AgentPersistence
    import Foundation
    import Security

    public struct KeychainFieldKeyProvider: Sendable {
        private let service: String
        private let account: String

        public init(
            service: String = "com.yusuf.agentcontrol.helper.persistence",
            account: String = "sensitive-field-key-v1"
        ) {
            self.service = service
            self.account = account
        }

        public func loadOrCreateCipher() throws -> AESGCMFieldCipher {
            if let existing = try load() {
                return try AESGCMFieldCipher(keyData: existing)
            }
            var key = Data(repeating: 0, count: 32)
            let randomStatus = key.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
            }
            guard randomStatus == errSecSuccess else { throw LocalIPCError.unavailable }
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData: key
            ]
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem, let existing = try load() {
                return try AESGCMFieldCipher(keyData: existing)
            }
            guard status == errSecSuccess else { throw LocalIPCError.unavailable }
            return try AESGCMFieldCipher(keyData: key)
        }

        private func load() throws -> Data? {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess, let data = result as? Data else { throw LocalIPCError.unavailable }
            return data
        }
    }
#endif
