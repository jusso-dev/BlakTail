import BlakTailCore
import SwiftUI

struct EndpointDetailView: View {
    @Bindable var model: PhoneModel
    let device: EndpointDevice

    @State private var friendlyName: String
    @State private var approvedRoutes: Set<String>
    @State private var showingRevokeConfirmation = false
    @AccessibilityFocusState private var focusOnRevoke: Bool

    init(model: PhoneModel, device: EndpointDevice) {
        self.model = model
        self.device = device
        _friendlyName = State(initialValue: device.friendlyName ?? "")
        _approvedRoutes = State(initialValue: Set(device.approvedRoutes))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("State") {
                    Label(device.credentialState.label, systemImage: device.credentialState.symbol)
                        .foregroundStyle(statusColour)
                }
                .accessibilityElement(children: .combine)
                LabeledContent("Network", value: device.organisationName)
            }

            Section {
                TextField("Friendly name", text: $friendlyName, prompt: Text(device.technicalName))
                    .disabled(!canEdit)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .accessibilityHint(
                        "Changes the label people see. The technical and MagicDNS names stay unchanged."
                    )
                    .onSubmit { saveFriendlyName() }
                LabeledContent("Length", value: "\(friendlyNameLength) of 64 characters")
                    .foregroundStyle(friendlyNameLength > 64 ? Color.red : Color.secondary)
                Button("Use technical name") {
                    friendlyName = ""
                }
                .disabled(!canEdit || friendlyName.isEmpty)
                Button("Save name") {
                    saveFriendlyName()
                }
                .disabled(
                    !canEdit ||
                        friendlyNameLength > 64 ||
                        friendlyName.trimmingCharacters(in: .whitespacesAndNewlines) == (device.friendlyName ?? "") ||
                        isPending
                )
                LabeledContent("Technical name", value: device.technicalName)
                    .textSelection(.enabled)
            } header: {
                Text("Friendly name")
            } footer: {
                Text("Friendly names are for people. MagicDNS and WireGuard identity stay stable.")
            }

            Section("Network identity") {
                CopyableValue(label: "MagicDNS", value: device.dnsName)
                CopyableValue(
                    label: device.allowedIPs.count == 1 ? "Address" : "Addresses",
                    value: device.allowedIPs.joined(separator: ", ")
                )
                if let endpoint = device.endpoint, !endpoint.isEmpty {
                    CopyableValue(label: "Observed endpoint", value: endpoint)
                }
                CopyableValue(label: "Node ID", value: device.nodeID)
                CopyableValue(label: "WireGuard public key", value: device.wireGuardPublicKey)
            }

            Section("Credential") {
                LabeledContent("Expires") {
                    Text(expiryDate, format: .dateTime.day().month().year())
                }
                LabeledContent("Enrolled") {
                    Text(createdDate, format: .dateTime.day().month().year())
                }
            }

            if !device.tags.isEmpty {
                Section("Tags") {
                    Text(device.tags.joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }

            if !device.advertisedRoutes.isEmpty {
                Section {
                    ForEach(device.advertisedRoutes, id: \.self) { route in
                        Toggle(isOn: routeBinding(route)) {
                            VStack(alignment: .leading) {
                                Text(route == "0.0.0.0/0" ? "Exit node" : route)
                                    .monospaced()
                                if route == "0.0.0.0/0" {
                                    Text("Allows approved devices to send internet traffic through this endpoint.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!canEdit || (device.expired && !device.approvedRoutes.contains(route)))
                    }
                    Button("Save route approvals") {
                        Task {
                            _ = await model.approveRoutes(
                                device.advertisedRoutes.filter(approvedRoutes.contains),
                                for: device
                            )
                        }
                    }
                    .disabled(!canEdit || approvedRoutes == Set(device.approvedRoutes) || isPending)
                } header: {
                    Text("Advertised routes")
                }
            }

            if canEdit {
                Section {
                    Button("Revoke endpoint", role: .destructive) {
                        showingRevokeConfirmation = true
                    }
                    .disabled(isPending)
                    .accessibilityFocused($focusOnRevoke)
                } header: {
                    Text("Administration")
                } footer: {
                    Text("Revocation removes this endpoint from future peer updates. It does not erase the device.")
                }
            }
        }
        .navigationTitle(device.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Revoke \(device.displayName)?", isPresented: $showingRevokeConfirmation) {
            Button("Cancel", role: .cancel) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    focusOnRevoke = true
                }
            }
            Button("Revoke endpoint", role: .destructive) {
                Task {
                    _ = await model.revoke(device)
                    try? await Task.sleep(for: .milliseconds(100))
                    focusOnRevoke = true
                }
            }
        } message: {
            Text("The endpoint will lose access to \(device.organisationName). This action is recorded in the audit log.")
        }
    }

    private var canEdit: Bool {
        device.canMutate && !device.revoked
    }

    private var isPending: Bool {
        model.pendingDeviceID == device.id
    }

    private var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(device.createdAt))
    }

    private var expiryDate: Date {
        Date(timeIntervalSince1970: TimeInterval(device.credentialExpiresAt))
    }

    private var statusColour: Color {
        switch device.credentialState {
        case .active: return .green
        case .expiresSoon: return .orange
        case .expired, .revoked: return .red
        }
    }

    private var friendlyNameLength: Int {
        friendlyName.unicodeScalars.count
    }

    private func routeBinding(_ route: String) -> Binding<Bool> {
        Binding(
            get: { approvedRoutes.contains(route) },
            set: { enabled in
                if enabled {
                    approvedRoutes.insert(route)
                } else {
                    approvedRoutes.remove(route)
                }
            }
        )
    }

    private func saveFriendlyName() {
        guard friendlyNameLength <= 64 else { return }
        Task { _ = await model.rename(device, to: friendlyName) }
    }
}
