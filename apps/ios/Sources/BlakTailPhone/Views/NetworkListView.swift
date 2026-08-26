import BlakTailCore
import SwiftUI

struct NetworkListView: View {
    @Bindable var model: PhoneModel
    @State private var scope: NetworkScope = .all
    @State private var searchText = ""
    @AccessibilityFocusState private var focusOnSignIn: Bool

    var body: some View {
        Group {
            if !model.isSignedIn {
                signInUnavailable
            } else if model.isLoadingDevices && model.devices.isEmpty {
                ProgressView("Loading endpoints…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading endpoints")
            } else if visibleDevices.isEmpty {
                emptyState
            } else {
                endpointList
            }
        }
        .navigationTitle(scopeTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar { toolbar }
        .searchable(text: $searchText, prompt: "Search endpoints")
        .refreshable { await model.refreshDevices() }
        .safeAreaInset(edge: .bottom) { feedback }
    }

    private var signInUnavailable: some View {
        ContentUnavailableView {
            Label("Sign in required", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Sign in once to see endpoints across every network you can access.")
        } actions: {
            Button("Sign in") {
                Task { await model.signIn() }
            }
            .disabled(model.isBusy || model.consoleBaseURL == nil)
            .accessibilityFocused($focusOnSignIn)
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "No endpoints yet",
                systemImage: "iphone",
                description: Text("Connect this iPhone from the This iPhone tab, or enrol another device from the console.")
            )
        } else {
            ContentUnavailableView.search
        }
    }

    private var endpointList: some View {
        List(visibleDevices) { device in
            NavigationLink(value: device) {
                EndpointRowView(device: device)
            }
            .accessibilityInputLabels([device.displayName, device.technicalName])
        }
        .navigationDestination(for: EndpointDevice.self) { device in
            EndpointDetailView(model: model, device: device)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refreshDevices() }
            } label: {
                Label("Refresh endpoints", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoadingDevices)
            .frame(minWidth: 44, minHeight: 44)
        }
        if let organisations = model.session?.organisations, !organisations.isEmpty {
            ToolbarItem(placement: .principal) {
                Picker("Network", selection: $scope) {
                    Text("All networks").tag(NetworkScope.all)
                    ForEach(organisations) { organisation in
                        Text(organisation.name).tag(NetworkScope.organisation(organisation.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Network filter")
                .accessibilityValue(scopeTitle)
            }
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
        case .all:
            return "All networks"
        case .organisation(let id):
            return model.session?.organisations.first(where: { $0.id == id })?.name ?? "Network"
        }
    }

    private var visibleDevices: [EndpointDevice] {
        model.devices(in: scope, matching: searchText)
    }
}

struct FeedbackBanner: View {
    let message: String
    let symbol: String
    let isError: Bool

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(isError ? Color.red.opacity(0.12) : Color.green.opacity(0.12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isError ? "Error: \(message)" : message)
    }
}
