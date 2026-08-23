import BlakTailCore
import SwiftUI

@main
struct BlakTailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .onAppear { appDelegate.model = model }
        } label: {
            Label("BlakTail", systemImage: model.menuBarSymbol)
        }

        Window("BlakTail", id: "main") {
            StatusWindow(model: model)
                .frame(minWidth: 360, minHeight: 420)
        }
        .defaultSize(width: 380, height: 480)

        Window("About BlakTail", id: "about") {
            AboutView()
                .frame(width: 420, height: 260)
        }
        .windowResizability(.contentSize)
    }
}
