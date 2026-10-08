import AppKit
import SwiftUI

@main
struct GeleitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: ProfileStore
    @StateObject private var tunnel: TunnelController

    init() {
        let store = ProfileStore()
        let tunnel = TunnelController()
        tunnel.profileLookup = { [weak store] id in store?.profile(id: id) }
        AppDelegate.tunnel = tunnel
        _store = StateObject(wrappedValue: store)
        _tunnel = StateObject(wrappedValue: tunnel)
        tunnel.refreshHelperStatus()
        #if DEBUG
        DispatchQueue.main.async { DebugSnapshot.apply(store: store, tunnel: tunnel) }
        #endif
    }

    var body: some Scene {
        Window("Geleit", id: "console") {
            ConsoleView()
                .environmentObject(store)
                .environmentObject(tunnel)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 720)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuContent()
                .environmentObject(store)
                .environmentObject(tunnel)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: tunnel.phase))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var tunnel: TunnelController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppDelegate.tunnel?.shutdownSync() }
    }
}

/// Abre/foca o console. Necessário porque o app não aparece no Dock (LSUIElement).
@MainActor
func showConsole(_ openWindow: OpenWindowAction) {
    openWindow(id: "console")
    NSApp.activate(ignoringOtherApps: true)
}
