import AppKit
import BlakTailCore
import SwiftUI

struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(model.connectionState.label, systemImage: model.menuBarSymbol)
                .font(.headline)
            if let address = model.agentStatus.address {
                Text("BlakTail address: \(address)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let session = model.session {
                Text(
                    "\(model.activeDeviceCount) active credentials, \(model.devices.count) endpoints across \(session.organisations.count) \(session.organisations.count == 1 ? "network" : "networks")"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Divider()
            if model.isSignedIn || model.agentStatus.nodeID != nil {
                Button(model.connectionState == .connected ? "Disconnect" : "Connect") {
                    Task {
                        if model.connectionState == .connected {
                            model.disconnect()
                        } else {
                            await model.connect()
                        }
                    }
                }
                .disabled(model.isBusy)
            }
            if model.isSignedIn {
                Button("Sign out") { model.signOut() }
            } else {
                Button("Sign in…") {
                    Task { await model.signIn() }
                }
                .disabled(model.isBusy)
            }
            Divider()
            Button("Open Endpoint Manager…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o", modifiers: .command)
            SettingsLink {
                Text("Settings…")
            }
            Button("About BlakTail") {
                openWindow(id: "about")
            }
            Divider()
            Button("Quit BlakTail") {
                model.prepareToQuit()
                NSApp.terminate(nil)
            }
        }
        .padding(4)
        .onAppear { model.bootstrap() }
    }
}
