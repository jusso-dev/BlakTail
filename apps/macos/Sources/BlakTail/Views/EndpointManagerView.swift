import BlakTailCore
import SwiftUI

private enum EndpointScope: Hashable {
    case thisMac
    case all
    case organisation(String)
}

struct EndpointManagerView: View {
    @Bindable var model: AppModel
    @State private var scope: EndpointScope = .all
    @State private var selectedDeviceID: String?
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
        } detail: {
            detailColumn
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh endpoints", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingDevices)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh local status and every authorised network")
            }
        }
        .safeAreaInset(edge: .top) {
            feedback
        }
        .onAppear { model.bootstrap() }
        .onChange(of: visibleDevices.map(\.id)) { _, identifiers in
            if let selectedDeviceID, !identifiers.contains(selectedDeviceID) {
                self.selectedDeviceID = identifiers.first
            } else if selectedDeviceID == nil {
                selectedDeviceID = identifiers.first
            }
        }
    }

    private var sidebar: some View {
        List(selection: $scope) {
            Section {
                Label {
                    HStack {
                        Text("This Mac")
                        Spacer()
                        Text(model.connectionState.label)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: model.menuBarSymbol)
                }
                .tag(EndpointScope.thisMac)
                .accessibilityLabel("This Mac, \(model.connectionState.label)")
            }

            Section("Networks") {
                Label {
                    HStack {
                        Text("All networks")
                        Spacer()
                        Text("\(model.devices.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                .tag(EndpointScope.all)

                ForEach(model.session?.organisations ?? []) { organisation in
                    Label {
                        HStack {
                            Text(organisation.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(deviceCount(in: organisation.id))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: "building.2")
                    }
                    .tag(EndpointScope.organisation(organisation.id))
                    .accessibilityLabel(
                        "\(organisation.name), \(deviceCount(in: organisation.id)) endpoints"
                    )
                }
            }

            if let session = model.session {
                Section("Account") {
                    VStack(alignment: .leading) {
                        Text(session.email)
                            .lineLimit(1)
                        Text("\(session.organisations.count) accessible \(session.organisations.count == 1 ? "network" : "networks")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let lastRefreshedAt = model.lastRefreshedAt {
                            Text("Updated \(lastRefreshedAt, style: .relative)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("BlakTail")
    }

    @ViewBuilder
    private var contentColumn: some View {
        if scope == .thisMac {
            LocalMacSummaryView(model: model)
                .navigationTitle("This Mac")
        } else if !model.isSignedIn {
            ContentUnavailableView {
                Label("Sign in required", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Sign in once to see endpoints across every network you can access.")
            } actions: {
                Button("Sign in…") {
                    Task { await model.signIn() }
                }
                .disabled(model.isBusy)
            }
            .navigationTitle(scopeTitle)
        } else if model.isLoadingDevices && model.devices.isEmpty {
            ProgressView("Loading endpoints…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(scopeTitle)
        } else if visibleDevices.isEmpty {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No endpoints yet",
                    systemImage: "desktopcomputer",
                    description: Text("Enrol a device from this network's console, then refresh.")
                )
                .navigationTitle(scopeTitle)
            } else {
                ContentUnavailableView.search(text: searchText)
                    .searchable(text: $searchText, prompt: "Search endpoints")
                    .navigationTitle(scopeTitle)
            }
        } else {
            List(visibleDevices, selection: $selectedDeviceID) { device in
                EndpointRow(device: device, isLocal: device.nodeID == model.agentStatus.nodeID)
                    .tag(device.id)
            }
            .searchable(text: $searchText, prompt: "Search endpoints")
            .navigationTitle(scopeTitle)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if scope == .thisMac {
            LocalMacView(model: model)
        } else if let device = selectedDevice {
            EndpointDetailView(model: model, device: device)
                .id(device)
        } else {
            ContentUnavailableView(
                "Select an endpoint",
                systemImage: "desktopcomputer",
                description: Text("Choose a machine to inspect its network identity and controls.")
            )
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = model.lastError {
            FeedbackBanner(message: error, symbol: "exclamationmark.triangle.fill", isError: true)
        } else if !model.inventoryErrors.isEmpty {
            FeedbackBanner(
                message: model.inventoryErrors.joined(separator: " "),
                symbol: "exclamationmark.triangle",
                isError: true
            )
        } else if let message = model.feedbackMessage {
            FeedbackBanner(message: message, symbol: "checkmark.circle.fill", isError: false)
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .thisMac: return "This Mac"
        case .all: return "All networks"
        case .organisation(let id):
            return model.session?.organisations.first(where: { $0.id == id })?.name ?? "Network"
        }
    }

    private var visibleDevices: [EndpointDevice] {
        let scoped: [EndpointDevice]
        switch scope {
        case .thisMac:
            scoped = []
        case .all:
            scoped = model.devices
        case .organisation(let organisationID):
            scoped = model.devices.filter { $0.organisationID == organisationID }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scoped }
        return scoped.filter { device in
            [
                device.displayName,
                device.technicalName,
                device.dnsName,
                device.organisationName,
                device.allowedIPs.joined(separator: " "),
                device.tags.joined(separator: " ")
            ].contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private var selectedDevice: EndpointDevice? {
        guard let selectedDeviceID else { return nil }
        return visibleDevices.first(where: { $0.id == selectedDeviceID })
    }

    private func deviceCount(in organisationID: String) -> Int {
        model.devices.filter { $0.organisationID == organisationID }.count
    }
}

private struct EndpointRow: View {
    let device: EndpointDevice
    let isLocal: Bool

    var body: some View {
        HStack {
            Image(systemName: device.credentialState.symbol)
                .foregroundStyle(statusColour)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                HStack {
                    Text(device.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if isLocal {
                        Text("This Mac")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(device.friendlyName == nil ? device.organisationName : "\(device.technicalName) · \(device.organisationName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(device.displayName), \(device.organisationName), \(device.credentialState.label)"
        )
    }

    private var statusColour: Color {
        switch device.credentialState {
        case .active: return .green
        case .expiresSoon: return .orange
        case .expired, .revoked: return .red
        }
    }
}

private struct FeedbackBanner: View {
    let message: String
    let symbol: String
    let isError: Bool

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(isError ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isError ? "Error: \(message)" : message)
    }
}
