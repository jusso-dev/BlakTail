import Foundation
import Security

public protocol SecretStoring: Sendable {
    func save(_ secret: String) throws
    func load() throws -> String?
    func delete() throws
}

/// In-memory secret store for tests. Hosted CI must not depend on a login Keychain.
public final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init(_ value: String? = nil) {
        self.value = value
    }

    public func save(_ secret: String) {
        lock.lock()
        value = secret
        lock.unlock()
    }

    public func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func delete() {
        lock.lock()
        value = nil
        lock.unlock()
    }
}

public enum KeychainStoreError: LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain error (\(status))."
        }
    }
}

/// Stores session tokens and node enrolment in the Keychain. Never writes them to disk logs.
public struct KeychainStore: SecretStoring, Sendable {
    public var service: String
    public var account: String
    public var accessGroup: String?

    public static let session = KeychainStore(
        service: "au.org.blaktail.desktop",
        account: "better-auth.session_token"
    )

    public static let phoneSession = KeychainStore(
        service: "au.org.blaktail.ios",
        account: "better-auth.session_token"
    )

    /// Shared with the packet-tunnel extension. The access group is the Team ID
    /// prefixed keychain group, never the bare `group.` app-group string.
    public static var phoneEnrollment: KeychainStore {
        KeychainStore(
            service: "au.org.blaktail.ios",
            account: "node.enrollment",
            accessGroup: BlakTailIdentifiers.keychainAccessGroup()
        )
    }

    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    public func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup, !accessGroup.isEmpty {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
