import AppKit
import BlakTailCore
import SwiftUI

struct EndpointDetailView: View {
    @Bindable var model: AppModel
    let device: EndpointDevice

    @State private var friendlyName: String
    @State private var approvedRoutes: Set<String>
    @State private var showingRevokeConfirmation = false

    init(model: AppModel, device: EndpointDevice) {
        self.model = model
        self.device = device
        _friendlyName = State(initialValue: device.friendlyName ?? "")
        _approvedRoutes = State(initialValue: Set(device.approvedRoutes))
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Image(systemName: device.credentialState.symbol)
                        .font(.system(size: 30))
                        .foregroundStyle(statusColour)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(device.displayName)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text("\(device.credentialState.label) in \(device.organisationName)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.pendingDeviceID == device.id {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving endpoint changes")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(device.displayName), \(device.credentialState.label), \(device.organisationName)"
                )
            }

            Section("Friendly name") {
                TextField("Friendly name", text: $friendlyName, prompt: Text(device.technicalName))
                    .disabled(!canEdit)
                    .accessibilityHint(
                        "Changes the label people see. The technical and MagicDNS names stay unchanged."
                    )
                    .onSubmit { saveFriendlyName() }

                HStack {
                    Text("\(friendlyNameLength)/64 characters")
                        .font(.caption)
                        .foregroundStyle(friendlyNameLength > 64 ? .red : .secondary)
                    Spacer()
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
                }

                Text("Technical name: \(device.technicalName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
                LabeledContent("Network", value: device.organisationName)
                LabeledContent("Node ID", value: device.nodeID)
                    .monospaced()
                    .textSelection(.enabled)
                LabeledContent("WireGuard public key", value: device.wireGuardPublicKey)
                    .monospaced()
                    .textSelection(.enabled)
            }

            Section("Credential") {
                LabeledContent("State", value: device.credentialState.label)
                LabeledContent {
                    Text(expiryDate, style: .date)
                } label: {
                    Text("Expires")
                }
                LabeledContent {
                    Text(createdDate, style: .date)
                } label: {
                    Text("Enrolled")
                }
            }

            if !device.tags.isEmpty {
                Section("Tags") {
                    Text(device.tags.joined(separator: ", "))
                        .textSelection(.enabled)
                }
            }

            if !device.advertisedRoutes.isEmpty {
                Section("Advertised routes") {
                    ForEach(device.advertisedRoutes, id: \.self) { route in
                        Toggle(isOn: routeBinding(route)) {
                            VStack(alignment: .leading) {
                                Text(route == "0.0.0.0/0" ? "Exit node" : route)
                                    .monospaced()
                                if route == "0.0.0.0/0" {
                                    Text("Allows approved devices to send internet traffic through this endpoint.")
                                        .font(.caption)
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
                }
            }

            if canEdit {
                Section("Administration") {
                    Button("Revoke endpoint…", role: .destructive) {
                        showingRevokeConfirmation = true
                    }
                    .disabled(isPending)
                    Text("Revocation removes this endpoint from future peer updates. It does not erase the device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(device.displayName)
        .alert("Revoke \(device.displayName)?", isPresented: $showingRevokeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke endpoint", role: .destructive) {
                Task { _ = await model.revoke(device) }
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

private struct CopyableValue: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(value)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy \(label.lowercased())")
                .help("Copy \(label.lowercased())")
            }
        }
    }
}
