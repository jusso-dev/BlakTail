import BlakTailCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: PhoneModel
    @State private var showingSignOut = false
    @AccessibilityFocusState private var focusOnSignOut: Bool

    var body: some View {
        Form {
            Section {
                TextField("Console URL", text: $model.preferences.consoleBaseURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit { model.savePreferences() }
            } header: {
                Text("Console")
            } footer: {
                if model.consoleBaseURL == nil {
                    Label(
                        "Enter a valid HTTPS console address.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                } else {
                    Text("Use the HTTPS address operated for your organisation in Australia.")
                }
            }

            Section {
                TextField("Device name", text: $model.preferences.deviceName)
                    .disabled(model.enrollment != nil)
                    .onSubmit { model.savePreferences() }
                Text("This becomes the stable technical name at enrolment. Friendly names can be changed later without changing MagicDNS identity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LabeledContent("Tunnel") {
                    Label(model.connectionState.label, systemImage: model.connectionSymbol)
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("This iPhone")
            }

            if let organisations = model.session?.organisations, !organisations.isEmpty {
                Section("Preferred network") {
                    Picker("Network", selection: organisationBinding) {
                        ForEach(organisations) { organisation in
                            Text(organisation.name).tag(organisation.id)
                        }
                    }
                    .accessibilityHint("Chooses which organisation-scoped pages prefer this network.")
                }
            }

            if let session = model.session {
                Section("Account") {
                    LabeledContent("Signed in as", value: session.email)
                    LabeledContent("Role", value: roleLabel(session.role))
                    LabeledContent(
                        "Accessible networks",
                        value: "\(session.organisations.count)"
                    )
                    if let lastRefreshedAt = model.lastRefreshedAt {
                        LabeledContent("Updated") {
                            Text(lastRefreshedAt, style: .relative)
                        }
                    }
                    Button("Sign out", role: .destructive) {
                        showingSignOut = true
                    }
                    .accessibilityFocused($focusOnSignOut)
                }
            } else {
                Section("Account") {
                    Button("Sign in") {
                        Task { await model.signIn() }
                    }
                    .disabled(model.isBusy || model.consoleBaseURL == nil)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }

            Section("Onshore") {
                LabeledContent("Region", value: "Sydney, Australia")
                LabeledContent("Cloud region", value: "ap-southeast-2")
                Text("Session tokens stay in the iPhone Keychain. The console URL is the only preference stored on device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("About BlakTail") {
                Text(Tagline.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .onDisappear { model.savePreferences() }
        .confirmationDialog(
            "Sign out of BlakTail?",
            isPresented: $showingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                model.signOut()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    focusOnSignOut = true
                }
            }
            Button("Cancel", role: .cancel) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    focusOnSignOut = true
                }
            }
        } message: {
            Text("This removes the session token from Keychain. This iPhone stays enrolled until you leave the network.")
        }
    }

    private var organisationBinding: Binding<String> {
        Binding(
            get: { model.selectedOrganisation?.id ?? "" },
            set: { model.selectOrganisation($0) }
        )
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "owner": return "Owner"
        case "admin": return "Admin"
        case "member": return "Member"
        default: return role
        }
    }
}
