#if canImport(Security)
    import Foundation
    import Security

    public enum CompanionKeyStoreError: Error, Sendable {
        case unexpectedStatus(OSStatus)
        case invalidData
    }

    public struct CompanionKeyStore: Sendable {
        private let service: String
        private let accessGroup: String?

        public init(
            service: String = "com.yusuf.agentcontrol.companion-keys",
            accessGroup: String? = nil
        ) {
            self.service = service
            self.accessGroup = accessGroup
        }

        public func save(_ data: Data, account: String) throws {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw CompanionKeyStoreError.unexpectedStatus(status) }
        }

        public func load(account: String) throws -> Data? {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess else { throw CompanionKeyStoreError.unexpectedStatus(status) }
            guard let data = result as? Data else { throw CompanionKeyStoreError.invalidData }
            return data
        }

        public func delete(account: String) throws {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CompanionKeyStoreError.unexpectedStatus(status)
            }
        }
    }
#endif
