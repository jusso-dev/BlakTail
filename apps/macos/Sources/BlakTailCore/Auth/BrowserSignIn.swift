import AppKit
import AuthenticationServices
import Foundation

public enum BrowserSignInError: LocalizedError, Sendable, Equatable {
    case cancelled
    case missingToken
    case invalidCallback

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign-in was cancelled."
        case .missingToken:
            return "The console did not return a session token."
        case .invalidCallback:
            return "The sign-in callback URL was not recognised."
        }
    }
}

/// Opens the onshore console in ASWebAuthenticationSession and captures the callback token.
@MainActor
public final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    public static let callbackScheme = "blaktail"

    public override init() {
        super.init()
    }

    public func signIn(consoleBaseURL: URL) async throws -> String {
        var components = URLComponents(url: consoleBaseURL.appending(path: "desktop/auth"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: "\(Self.callbackScheme)://auth/callback")
        ]
        let start = components.url!

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: start,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: BrowserSignInError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: BrowserSignInError.invalidCallback)
                    return
                }
                do {
                    continuation.resume(returning: try Self.token(from: callbackURL))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            if !session.start() {
                continuation.resume(throwing: BrowserSignInError.invalidCallback)
            }
        }
    }

    public nonisolated static func token(from callbackURL: URL) throws -> String {
        if let fragment = callbackURL.fragment,
           let token = queryValue("token", in: fragment),
           !token.isEmpty {
            return token
        }
        if let token = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "token" })?
            .value,
           !token.isEmpty {
            return token
        }
        throw BrowserSignInError.missingToken
    }

    nonisolated private static func queryValue(_ name: String, in fragment: String) -> String? {
        fragment
            .split(separator: "&")
            .compactMap { pair -> String? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == name else { return nil }
                return parts[1].removingPercentEncoding
            }
            .first
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
