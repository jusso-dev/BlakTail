import BlakTailCore

extension AppModel {
    func connect() async {
        if agentStatus.nodeID != nil {
            isBusy = true
            connectionState = .connecting
            lastError = nil
            feedbackMessage = nil
            defer { isBusy = false }
            do {
                try agent.resume()
                refreshAgentStatus()
                feedbackMessage = "This Mac resumed its saved BlakTail enrolment."
            } catch {
                connectionState = .disconnected
                lastError = error.localizedDescription
                refreshAgentStatus()
            }
            return
        }

        guard let token = try? keychain.load(), !token.isEmpty else {
            lastError = "Sign in before connecting."
            return
        }
        guard let base = consoleBaseURL else {
            lastError = "Set a valid onshore console URL first."
            return
        }
        guard let organisation = selectedOrganisation else {
            lastError = "Choose a network for this Mac."
            return
        }
        guard organisation.canMutate else {
            lastError = "An owner or admin must enrol this Mac in \(organisation.name)."
            return
        }

        isBusy = true
        connectionState = .connecting
        lastError = nil
        feedbackMessage = nil
        defer { isBusy = false }

        var material: JoinKeyMaterial?
        do {
            let client = ConsoleClient(sessionToken: token, baseURL: base)
            material = try await client.mintJoinKey(organisationID: organisation.id)
            var join = material!
            defer {
                join.scrub()
                material?.scrub()
            }
            let coordinator = join.coordinatorURL.isEmpty
                ? preferences.coordinatorURL
                : join.coordinatorURL
            preferences.coordinatorURL = coordinator
            preferences.save()

            try agent.connect(
                joinKey: join.key,
                coordinator: coordinator,
                name: preferences.deviceName
            )
            connectionState = .connected
            refreshAgentStatus()
            feedbackMessage = "This Mac is connected to \(organisation.name)."
            await refreshDevices()
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
        feedbackMessage = nil
        defer { isBusy = false }
        do {
            try agent.pause()
            refreshAgentStatus()
            connectionState = .disconnected
            feedbackMessage = "This Mac is disconnected."
        } catch {
            lastError = error.localizedDescription
            refreshAgentStatus()
            connectionState = agentStatus.connected ? .connected : .disconnected
        }
    }

    func refreshAgentStatus() {
        do {
            let status = try agent.status()
            agentStatus = status
            if status.connected {
                connectionState = .connected
            } else if connectionState == .connected {
                connectionState = .disconnected
            }
        } catch {
            // A background status probe is advisory. Action failures remain visible.
        }
    }
}
