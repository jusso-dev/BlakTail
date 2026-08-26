import CryptoKit
import Foundation

public enum WireGuardKeyError: LocalizedError, Sendable {
    case invalidBase64
    case invalidLength

    public var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return "WireGuard key is not valid base64."
        case .invalidLength:
            return "WireGuard key must be 32 bytes."
        }
    }
}

/// X25519 keypair encoded the same way `blaktaild` stores keys (standard base64).
public struct WireGuardKeypair: Equatable, Sendable {
    public var privateKey: String
    public var publicKey: String

    public init(privateKey: String, publicKey: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    public static func generate() -> WireGuardKeypair {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return WireGuardKeypair(
            privateKey: privateKey.rawRepresentation.base64EncodedString(),
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    public static func publicKey(fromPrivateKeyBase64 value: String) throws -> String {
        let raw = try rawKey(value)
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        return privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    public static func rawKey(_ base64: String) throws -> Data {
        guard let data = Data(base64Encoded: base64) else {
            throw WireGuardKeyError.invalidBase64
        }
        guard data.count == 32 else {
            throw WireGuardKeyError.invalidLength
        }
        return data
    }

    public mutating func scrubPrivateKey() {
        privateKey = String(repeating: "\0", count: privateKey.count)
        privateKey = ""
    }
}
