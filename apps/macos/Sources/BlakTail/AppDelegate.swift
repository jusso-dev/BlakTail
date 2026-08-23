import AppKit
import SwiftUI

/// Ensures quit clears transient UI state without leaving join-key material in process argv/env.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareToQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
