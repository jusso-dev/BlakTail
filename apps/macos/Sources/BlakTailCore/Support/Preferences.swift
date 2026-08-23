import Foundation

/// Non-secret preferences stored in UserDefaults. Session tokens stay in Keychain.
public struct Preferences: Equatable, Sendable {
    public var consoleBaseURL: String
    public var coordinatorURL: String
    public var deviceName: String
    public var tailnetAddress: String

    public static let defaults = Preferences(
        consoleBaseURL: "https://console.example.org.au",
        coordinatorURL: "https://coord.example.org.au",
        deviceName: Host.current().localizedName ?? "mac",
        tailnetAddress: "100.64.0.1/32"
    )

    private enum Key {
        static let consoleBaseURL = "consoleBaseURL"
        static let coordinatorURL = "coordinatorURL"
        static let deviceName = "deviceName"
        static let tailnetAddress = "tailnetAddress"
    }

    public init(
        consoleBaseURL: String,
        coordinatorURL: String,
        deviceName: String,
        tailnetAddress: String
    ) {
        self.consoleBaseURL = consoleBaseURL
        self.coordinatorURL = coordinatorURL
        self.deviceName = deviceName
        self.tailnetAddress = tailnetAddress
    }

    public static func load(defaults: UserDefaults = .standard) -> Preferences {
        Preferences(
            consoleBaseURL: defaults.string(forKey: Key.consoleBaseURL) ?? Self.defaults.consoleBaseURL,
            coordinatorURL: defaults.string(forKey: Key.coordinatorURL) ?? Self.defaults.coordinatorURL,
            deviceName: defaults.string(forKey: Key.deviceName) ?? Self.defaults.deviceName,
            tailnetAddress: defaults.string(forKey: Key.tailnetAddress) ?? Self.defaults.tailnetAddress
        )
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(consoleBaseURL, forKey: Key.consoleBaseURL)
        defaults.set(coordinatorURL, forKey: Key.coordinatorURL)
        defaults.set(deviceName, forKey: Key.deviceName)
        defaults.set(tailnetAddress, forKey: Key.tailnetAddress)
    }
}
