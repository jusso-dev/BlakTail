import BlakTailCore
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences: Preferences
    @Published var session: DesktopSession?
    @Published var selectedOrganisationId = ""
    @Published var connectionState: ConnectionState = .disconnected
    @Published var agentStatus: AgentStatus = .disconnected
    @Published var lastError: String?
    @Published var isBusy = false

    private let keychain: KeychainStore
    private let agent: AgentController
    private let browserSignIn: BrowserSignIn
    private var statusTask: Task<Void, Never>?

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
        connectionState == .connected ? "network" : "network.slash"
    }

    func bootstrap() {
        refreshAgentStatus()
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { self?.refreshAgentStatus() }
            }
        }
        Task { await restoreSessionIfPossible() }
    }

    func prepareToQuit() {
        statusTask?.cancel()
        statusTask = nil
        // Session token remains in Keychain. Any in-flight join key lives only in local
        // connect() scope and is scrubbed before return — quit must not leave it in argv/env.
        lastError = nil
    }

    func savePreferences() {
        preferences.save()
    }

    func signIn() async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            guard let base = URL(string: preferences.consoleBaseURL) else {
                lastError = "Set a valid onshore console URL first."
                return
            }
            let token = try await browserSignIn.signIn(consoleBaseURL: base)
            try keychain.save(token)
            let client = ConsoleClient(sessionToken: token, baseURL: base)
            let desktop = try await client.fetchSession()
            session = desktop
            selectedOrganisationId = desktop.organisations.first?.id ?? ""
            if let coordinator = desktop.coordinatorURL, !coordinator.isEmpty {
                preferences.coordinatorURL = coordinator
                preferences.save()
            }
        } catch let error as BrowserSignInError where error == .cancelled {
            // User cancelled — no error banner.
        } catch {
            lastError = error.localizedDescription
            session = nil
        }
    }

    func signOut() {
        try? keychain.delete()
        session = nil
        selectedOrganisationId = ""
        lastError = nil
    }

    func connect() async {
        guard let token = try? keychain.load(), !token.isEmpty else {
            lastError = "Sign in before connecting."
            return
        }
        guard let base = URL(string: preferences.consoleBaseURL) else {
            lastError = "Set a valid onshore console URL first."
            return
        }

        isBusy = true
        connectionState = .connecting
        lastError = nil
        defer { isBusy = false }

        var material: JoinKeyMaterial?
        do {
            let client = ConsoleClient(sessionToken: token, baseURL: base)
            material = try await client.mintJoinKey(
                organisationId: selectedOrganisationId.isEmpty ? nil : selectedOrganisationId
            )
            var join = material!
            let coordinator = join.coordinatorURL.isEmpty ? preferences.coordinatorURL : join.coordinatorURL
            preferences.coordinatorURL = coordinator
            preferences.save()

            try agent.connect(
                joinKey: join.key,
                coordinator: coordinator,
                name: preferences.deviceName
            )
            join.scrub()
            material?.scrub()

            connectionState = .connected
            refreshAgentStatus()
        } catch {
            material?.scrub()
            connectionState = .disconnected
            lastError = error.localizedDescription
            refreshAgentStatus()
        }
    }

    func disconnect() {
        isBusy = true
        connectionState = .disconnecting
        lastError = nil
        defer { isBusy = false }
        do {
            try agent.disconnect()
            connectionState = .disconnected
            agentStatus = .disconnected
        } catch {
            lastError = error.localizedDescription
            refreshAgentStatus()
        }
    }

    private func restoreSessionIfPossible() async {
        guard let token = try? keychain.load(), !token.isEmpty else { return }
        guard let base = URL(string: preferences.consoleBaseURL) else { return }
        do {
            let desktop = try await ConsoleClient(sessionToken: token, baseURL: base).fetchSession()
            session = desktop
            selectedOrganisationId = desktop.organisations.first?.id ?? ""
            if let coordinator = desktop.coordinatorURL, !coordinator.isEmpty {
                preferences.coordinatorURL = coordinator
            }
        } catch {
            try? keychain.delete()
            session = nil
            selectedOrganisationId = ""
        }
    }

    private func refreshAgentStatus() {
        do {
            let status = try agent.status()
            agentStatus = status
            if status.connected {
                connectionState = .connected
            } else if connectionState == .connected {
                connectionState = .disconnected
            }
        } catch {
            // Status probe failures are soft; surface only when the user acts.
        }
    }
}
