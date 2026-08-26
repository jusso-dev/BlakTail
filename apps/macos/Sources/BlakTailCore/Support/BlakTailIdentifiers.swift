import Foundation
import Security

/// Bundle IDs, app group, and keychain group used by the iPhone client and its tunnel.
public enum BlakTailIdentifiers: Sendable {
    public static let phoneBundleID = "au.org.blaktail.ios"
    public static let tunnelBundleID = "au.org.blaktail.ios.tunnel"
    public static let appGroup = "group.au.org.blaktail.ios"
    public static let keychainGroupSuffix = "au.org.blaktail.ios.shared"
    public static let agentVersion = "0.1.0"
    public static let tunnelMTU = 1280

    /// `TEAMID.au.org.blaktail.ios.shared`. Nil when the process has no Team ID
    /// (unit tests, or an unsigned `swift test` host).
    public static func keychainAccessGroup() -> String? {
        guard let teamID else { return nil }
        return "\(teamID).\(keychainGroupSuffix)"
    }

    public static var teamID: String? {
        #if os(iOS)
        resolvedTeamID()
        #else
        nil
        #endif
    }

    #if os(iOS)
    private static func resolvedTeamID() -> String? {
        let seedAccount = "au.org.blaktail.ios.bundle-seed"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: phoneBundleID,
            kSecAttrAccount as String: seedAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data("seed".utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add.removeValue(forKey: kSecReturnAttributes as String)
            add.removeValue(forKey: kSecMatchLimit as String)
            _ = SecItemAdd(add as CFDictionary, nil)
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String
        else {
            return nil
        }
        return group.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
    }
    #endif
}
