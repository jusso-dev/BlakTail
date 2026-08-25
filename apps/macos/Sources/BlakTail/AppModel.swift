import BlakTailCore
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var preferences: Preferences
    var session: DesktopSession?
    var connectionState: ConnectionState = .disconnected
    var agentStatus: AgentStatus = .disconnected
    var devices: [EndpointDevice] = []
    var inventoryErrors: [String] = []
    var lastError: String?
    var feedbackMessage: String?
    var isBusy = false
    var isLoadingDevices = false
    var pendingDeviceID: String?
    var lastRefreshedAt: Date?

    @ObservationIgnored let keychain: KeychainStore
    @ObservationIgnored let agent: AgentController
    @ObservationIgnored let browserSignIn: BrowserSignIn
    @ObservationIgnored var statusTask: Task<Void, Never>?
    @ObservationIgnored var hasBootstrapped = false

    init(
        preferences: Preferences = .load(),
        keychain: KeychainStore = .session,
        agent: AgentController = .default,
        browserSignIn: BrowserSignIn? = nil
    ) {
        self.preferences = preferences
        self.keychain = keychain
        self.agent = agent
        self.browserSignIn = browserSignIn ?? BrowserSignIn()
    }

    var isSignedIn: Bool { session != nil }

    var menuBarSymbol: String {
        switch connectionState {
        case .connected: return "network"
        case .connecting, .disconnecting: return "network.badge.shield.half.filled"
        case .disconnected: return "network.slash"
        }
    }

    var selectedOrganisation: DesktopOrganisation? {
        guard let session else { return nil }
        return session.organisations.first(where: { $0.id == preferences.selectedOrganisationID })
            ?? session.organisations.first
    }

    var localDevice: EndpointDevice? {
        guard let nodeID = agentStatus.nodeID else { return nil }
        return devices.first(where: { $0.nodeID == nodeID })
    }

    var activeDeviceCount: Int {
        devices.filter { !$0.expired && !$0.revoked }.count
    }

    var consoleBaseURL: URL? {
        guard let url = URL(string: preferences.consoleBaseURL),
              url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost"
        else {
            return nil
        }
        return url
    }

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        refreshAgentStatus()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshAgentStatus()
            }
        }
        Task { await restoreSessionIfPossible() }
    }

    func prepareToQuit() {
        statusTask?.cancel()
        statusTask = nil
        lastError = nil
        feedbackMessage = nil
    }

    func savePreferences() {
        preferences.save()
    }

    func selectOrganisation(_ organisationID: String) {
        guard session?.organisations.contains(where: { $0.id == organisationID }) == true else {
            return
        }
        preferences.selectedOrganisationID = organisationID
        preferences.save()
    }
}
