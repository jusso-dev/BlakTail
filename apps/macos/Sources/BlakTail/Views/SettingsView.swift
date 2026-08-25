import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Console") {
                TextField("Console URL", text: $model.preferences.consoleBaseURL)
                    .textContentType(.URL)
                    .onSubmit { model.savePreferences() }
                if model.consoleBaseURL == nil {
                    Label(
                        "Enter a valid HTTPS console address.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                } else {
                    Text("Use the HTTPS address operated for your organisation in Australia.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("This Mac") {
                TextField("Device name", text: $model.preferences.deviceName)
                    .onSubmit { model.savePreferences() }
                Text("This becomes the stable technical name at enrolment. Friendly names can be changed later without changing MagicDNS identity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let organisations = model.session?.organisations, !organisations.isEmpty {
                    Picker("Default network", selection: organisationBinding) {
                        ForEach(organisations) { organisation in
                            Text(organisation.name).tag(organisation.id)
                        }
                    }
                    .disabled(model.agentStatus.nodeID != nil)
                    .help("An enrolled Mac keeps its network until it is re-enrolled")
                }
            }

            if let session = model.session {
                Section("Account") {
                    LabeledContent("Signed in as", value: session.email)
                    LabeledContent(
                        "Accessible networks",
                        value: "\(session.organisations.count)"
                    )
                    Button("Sign out", role: .destructive) {
                        model.signOut()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
        .onDisappear { model.savePreferences() }
    }

    private var organisationBinding: Binding<String> {
        Binding(
            get: { model.selectedOrganisation?.id ?? "" },
            set: { model.selectOrganisation($0) }
        )
    }
}
