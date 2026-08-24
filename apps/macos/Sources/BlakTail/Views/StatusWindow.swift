import BlakTailCore
import SwiftUI

struct StatusWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Account") {
                if let session = model.session {
                    LabeledContent("Signed in as", value: session.email)
                    if session.organisations.isEmpty {
                        LabeledContent("Organisation", value: session.organisationName)
                        LabeledContent("Role", value: session.role)
                    } else {
                        Picker("Network", selection: $model.selectedOrganisationId) {
                            ForEach(session.organisations) { organisation in
                                Text("\(organisation.name) · \(organisation.role)")
                                    .tag(organisation.id)
                            }
                        }
                        Text("\(session.organisations.count) accessible organisations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Sign out", role: .destructive, action: model.signOut)
                } else {
                    Text("Sign in with your onshore console account to connect.")
                        .foregroundStyle(.secondary)
                    Button("Sign in…") {
                        Task { await model.signIn() }
                    }
                    .disabled(model.isBusy)
                }
            }

            Section("Connection") {
                LabeledContent("Status", value: model.connectionState.label)
                LabeledContent("Device name") {
                    TextField("Device name", text: $model.preferences.deviceName)
                        .onSubmit { model.savePreferences() }
                }
                if let address = model.agentStatus.address {
                    LabeledContent("Reported address", value: address)
                }
                if let node = model.agentStatus.nodeID {
                    LabeledContent("Node", value: node)
                }
                if let error = model.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                HStack {
                    Button(model.connectionState == .connected ? "Disconnect" : "Connect") {
                        Task {
                            if model.connectionState == .connected {
                                model.disconnect()
                            } else {
                                await model.connect()
                            }
                        }
                    }
                    .disabled(model.isBusy || !model.isSignedIn)
                    .keyboardShortcut(.defaultAction)
                }
            }

            Section("Onshore endpoints") {
                TextField("Console URL", text: $model.preferences.consoleBaseURL)
                    .onSubmit { model.savePreferences() }
                TextField("Coordinator URL", text: $model.preferences.coordinatorURL)
                    .onSubmit { model.savePreferences() }
                Text("Use Australian-hosted console and coordinator URLs only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { model.bootstrap() }
        .onDisappear { model.savePreferences() }
    }
}
