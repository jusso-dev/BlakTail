import BlakTailCore
import SwiftUI

@main
struct BlakTailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .onAppear { appDelegate.model = model }
        } label: {
            Label("BlakTail", systemImage: model.menuBarSymbol)
        }

        Window("BlakTail Endpoint Manager", id: "main") {
            EndpointManagerView(model: model)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1_080, height: 700)
        .commands {
            SidebarCommands()
            CommandMenu("Connection") {
                Button(model.connectionState == .connected ? "Disconnect" : "Connect") {
                    Task {
                        if model.connectionState == .connected {
                            model.disconnect()
                        } else {
                            await model.connect()
                        }
                    }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.isBusy || (!model.isSignedIn && model.agentStatus.nodeID == nil))

                Button("Refresh Endpoints") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isLoadingDevices)
            }
        }

        Settings {
            SettingsView(model: model)
        }

        Window("About BlakTail", id: "about") {
            AboutView()
                .frame(width: 420, height: 260)
        }
        .windowResizability(.contentSize)
    }
}
