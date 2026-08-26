import BlakTailCore
import Foundation

extension PhoneModel {
    public func refreshDevices() async {
        guard let token = try? keychain.load(), !token.isEmpty, let base = consoleBaseURL else {
            devices = []
            inventoryErrors = []
            return
        }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        do {
            let inventory = try await ConsoleClient(
                sessionToken: token,
                baseURL: base,
                urlSession: urlSession
            ).fetchDevices()
            devices = inventory.devices
            inventoryErrors = inventory.errors
            lastError = nil
            lastRefreshedAt = Date()
        } catch ConsoleClientError.unauthorised {
            try? keychain.delete()
            session = nil
            devices = []
            inventoryErrors = []
            lastError = ConsoleClientError.unauthorised.localizedDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func rename(_ device: EndpointDevice, to friendlyName: String) async -> Bool {
        await mutate(device) { client in
            try await client.updateFriendlyName(
                nodeID: device.nodeID,
                organisationID: device.organisationID,
                friendlyName: friendlyName
            )
        }
    }

    public func approveRoutes(_ routes: [String], for device: EndpointDevice) async -> Bool {
        await mutate(device) { client in
            try await client.approveRoutes(
                nodeID: device.nodeID,
                organisationID: device.organisationID,
                approvedRoutes: routes
            )
        }
    }

    public func revoke(_ device: EndpointDevice) async -> Bool {
        let succeeded = await mutate(device) { client in
            try await client.revokeDevice(
                nodeID: device.nodeID,
                organisationID: device.organisationID
            )
        }
        if succeeded, device.nodeID == enrollment?.nodeID {
            try? await tunnel.stop()
            try? enrollmentStore.delete()
            enrollment = nil
            connectionState = .disconnected
        }
        return succeeded
    }

    private func mutate(
        _ device: EndpointDevice,
        operation: (ConsoleClient) async throws -> Void
    ) async -> Bool {
        guard let token = try? keychain.load(), !token.isEmpty, let base = consoleBaseURL else {
            lastError = "Sign in before changing a device."
            return false
        }
        pendingDeviceID = device.id
        lastError = nil
        feedbackMessage = nil
        defer { pendingDeviceID = nil }
        do {
            try await operation(ConsoleClient(sessionToken: token, baseURL: base, urlSession: urlSession))
            await refreshDevices()
            feedbackMessage = "\(device.displayName) was updated."
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
