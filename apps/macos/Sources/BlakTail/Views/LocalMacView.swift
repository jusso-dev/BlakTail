import BlakTailCore
import SwiftUI

struct LocalMacSummaryView: View {
    let model: AppModel

    var body: some View {
        List {
            Section("Connection") {
                Label(model.connectionState.label, systemImage: model.menuBarSymbol)
                    .font(.headline)
                if let network = model.localDevice?.organisationName ?? model.selectedOrganisation?.name {
                    LabeledContent("Network", value: network)
                }
                if let address = model.agentStatus.address {
                    LabeledContent("BlakTail address", value: address)
                        .monospaced()
                }
            }

            Section("Identity") {
                LabeledContent("Device name", value: model.preferences.deviceName)
                if let localDevice = model.localDevice {
                    LabeledContent("Shown as", value: localDevice.displayName)
                    LabeledContent("MagicDNS", value: localDevice.dnsName)
                        .monospaced()
                }
            }
        }
        .listStyle(.inset)
    }
}

struct LocalMacView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Image(systemName: model.menuBarSymbol)
                        .font(.system(size: 30))
                        .foregroundStyle(connectionColour)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(model.connectionState.label)
                            .font(.title2.weight(.semibold))
                        Text(connectionDescription)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Connection change in progress")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("This Mac is \(model.connectionState.label.lowercased())")
            }

            if let session = model.session {
                Section("Network for this Mac") {
                    Picker("Network", selection: organisationBinding) {
                        ForEach(session.organisations) { organisation in
                            Text(organisation.name).tag(organisation.id)
                        }
                    }
                    .disabled(model.agentStatus.nodeID != nil || model.isBusy)
                    .help("An enrolled Mac keeps its network until it is re-enrolled")

                    if let organisation = model.selectedOrganisation, !organisation.canMutate {
                        Label(
                            "An owner or admin must enrol this Mac in this network.",
                            systemImage: "person.badge.shield.checkmark"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Account") {
                    Text("Sign in once to choose from every network your account can access.")
                        .foregroundStyle(.secondary)
                    Button("Sign in…") {
                        Task { await model.signIn() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .keyboardShortcut(.defaultAction)
                }
            }

            Section {
                Button(model.connectionState == .connected ? "Disconnect" : "Connect") {
                    Task {
                        if model.connectionState == .connected {
                            model.disconnect()
                        } else {
                            await model.connect()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || !canToggleConnection)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(connectionActionHint)
            }

            Section("Local identity") {
                LabeledContent("Device name", value: model.preferences.deviceName)
                if let address = model.agentStatus.address {
                    LabeledContent("BlakTail address", value: address)
                        .monospaced()
                        .textSelection(.enabled)
                }
                if let nodeID = model.agentStatus.nodeID {
                    LabeledContent("Node ID", value: nodeID)
                        .monospaced()
                        .textSelection(.enabled)
                }
                if let dnsName = model.localDevice?.dnsName {
                    LabeledContent("MagicDNS", value: dnsName)
                        .monospaced()
                        .textSelection(.enabled)
                }
            }

            Section("Control plane") {
                LabeledContent("Console", value: model.preferences.consoleBaseURL)
                    .textSelection(.enabled)
                if !model.preferences.coordinatorURL.isEmpty {
                    LabeledContent("Coordinator", value: model.preferences.coordinatorURL)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("This Mac")
    }

    private var organisationBinding: Binding<String> {
        Binding(
            get: { model.selectedOrganisation?.id ?? "" },
            set: { model.selectOrganisation($0) }
        )
    }

    private var canToggleConnection: Bool {
        if model.connectionState == .connected { return true }
        if model.agentStatus.nodeID != nil { return true }
        return model.isSignedIn && model.selectedOrganisation?.canMutate == true
    }

    private var connectionActionHint: String {
        if model.connectionState == .connected {
            return "Pauses the local tunnel while retaining enrolment"
        }
        if model.agentStatus.nodeID != nil {
            return "Resumes the saved local enrolment"
        }
        return "Enrols and starts the local BlakTail tunnel"
    }

    private var connectionDescription: String {
        switch model.connectionState {
        case .connected:
            if let network = model.localDevice?.organisationName ?? model.selectedOrganisation?.name {
                return "Private paths through \(network) are available."
            }
            return "Private paths are available."
        case .connecting:
            return "Creating the local encrypted path."
        case .disconnecting:
            return "Closing the local encrypted path."
        case .disconnected:
            return "This Mac is not using a BlakTail network."
        }
    }

    private var connectionColour: Color {
        switch model.connectionState {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .disconnected: return .secondary
        }
    }
}
