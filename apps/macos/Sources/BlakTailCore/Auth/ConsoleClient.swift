import Foundation

public struct DesktopSession: Equatable, Sendable {
    public var email: String
    public var organisationName: String
    public var role: String
    public var coordinatorURL: String?

    public init(email: String, organisationName: String, role: String, coordinatorURL: String?) {
        self.email = email
        self.organisationName = organisationName
        self.role = role
        self.coordinatorURL = coordinatorURL
    }
}

public struct JoinKeyMaterial: Sendable {
    public var key: String
    public var expiresAt: Date
    public var coordinatorURL: String

    public init(key: String, expiresAt: Date, coordinatorURL: String) {
        self.key = key
        self.expiresAt = expiresAt
        self.coordinatorURL = coordinatorURL
    }

    public mutating func scrub() {
        key = String(repeating: "\0", count: key.count)
        key = ""
    }
}

public enum ConsoleClientError: LocalizedError, Sendable {
    case invalidURL
    case http(Int, String)
    case decoding
    case unauthorised

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The console URL is not valid."
        case .http(let code, let body):
            return "Console returned \(code): \(body)"
        case .decoding:
            return "Could not read the console response."
        case .unauthorised:
            return "Your session has expired. Sign in again."
        }
    }
}

/// Talks to the onshore Next.js console. Coordinator mutations go through the console, not offshore IdPs.
public struct ConsoleClient: Sendable {
    public var sessionToken: String
    public var baseURL: URL
    public var urlSession: URLSession

    public init(sessionToken: String, baseURL: URL, urlSession: URLSession = .shared) {
        self.sessionToken = sessionToken
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func fetchSession() async throws -> DesktopSession {
        let (data, response) = try await request(path: "/api/desktop/me", method: "GET", body: nil)
        guard let http = response as? HTTPURLResponse else { throw ConsoleClientError.decoding }
        if http.statusCode == 401 { throw ConsoleClientError.unauthorised }
        guard (200..<300).contains(http.statusCode) else {
            throw ConsoleClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(MeResponse.self, from: data)
        return DesktopSession(
            email: decoded.email,
            organisationName: decoded.organisationName,
            role: decoded.role,
            coordinatorURL: decoded.coordinatorUrl
        )
    }

    public func mintJoinKey(tags: [String] = [], expiresInSeconds: Int = 600) async throws -> JoinKeyMaterial {
        let payload = try JSONSerialization.data(withJSONObject: [
            "tags": tags,
            "expiresInSeconds": expiresInSeconds,
            "singleUse": true
        ])
        let (data, response) = try await request(path: "/api/desktop/join-key", method: "POST", body: payload)
        guard let http = response as? HTTPURLResponse else { throw ConsoleClientError.decoding }
        if http.statusCode == 401 { throw ConsoleClientError.unauthorised }
        guard (200..<300).contains(http.statusCode) else {
            throw ConsoleClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(JoinKeyResponse.self, from: data)
        return JoinKeyMaterial(
            key: decoded.key,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(decoded.expiresAt)),
            coordinatorURL: decoded.coordinatorUrl
        )
    }

    private func request(path: String, method: String, body: Data?) async throws -> (Data, URLResponse) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = baseURL.appending(path: trimmed)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await urlSession.data(for: request)
    }

    private struct MeResponse: Decodable {
        var email: String
        var organisationName: String
        var role: String
        var coordinatorUrl: String?
    }

    private struct JoinKeyResponse: Decodable {
        var key: String
        var expiresAt: Int
        var coordinatorUrl: String
    }
}
