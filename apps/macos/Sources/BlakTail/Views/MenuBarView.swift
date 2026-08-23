import AppKit
import BlakTailCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.connectionState.label)
                .font(.headline)
            if let address = model.agentStatus.address {
                Text("Tailnet IP: \(address)")
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
            if model.isSignedIn {
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
                Button("Sign out") { model.signOut() }
            } else {
                Button("Sign in…") {
                    Task { await model.signIn() }
                }
                .disabled(model.isBusy)
            }
            Button("Open BlakTail…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
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
