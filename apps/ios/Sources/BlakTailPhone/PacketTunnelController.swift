import BlakTailCore
import Foundation

public protocol PacketTunnelControlling: Sendable {
    func start() async throws
    func stop() async throws
    func isRunning() async -> Bool
}

public enum PacketTunnelController {
    public static var system: any PacketTunnelControlling {
        #if os(iOS)
        SystemPacketTunnelController()
        #else
        UnavailablePacketTunnelController()
        #endif
    }
}

public struct UnavailablePacketTunnelController: PacketTunnelControlling {
    public init() {}

    public func start() async throws {
        throw PacketTunnelControllerError.unavailable
    }

    public func stop() async throws {}

    public func isRunning() async -> Bool { false }
}

public enum PacketTunnelControllerError: LocalizedError, Sendable {
    case unavailable
    case startFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This host cannot start the iPhone packet tunnel."
        case .startFailed:
            return "Could not start the BlakTail packet tunnel."
        }
    }
}

#if os(iOS)
import NetworkExtension

public struct SystemPacketTunnelController: PacketTunnelControlling {
    public init() {}

    public func start() async throws {
        let manager = try await loadOrCreate()
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            throw PacketTunnelControllerError.startFailed
        }
    }

    public func stop() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        managers.first?.connection.stopVPNTunnel()
    }

    public func isRunning() async -> Bool {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        return managers.contains { $0.connection.status == .connected }
    }

    private func loadOrCreate() async throws -> NETunnelProviderManager {
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = existing.first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = BlakTailIdentifiers.tunnelBundleID
        proto.serverAddress = "BlakTail"
        proto.disconnectOnSleep = false
        manager.localizedDescription = "BlakTail"
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }
}
#endif
