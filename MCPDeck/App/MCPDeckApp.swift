import SwiftUI
import MCPDeckCore

@main
struct MCPDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("MCP Deck", systemImage: model.globalHealth.menuBarSymbol) {
            MenuBarContent()
                .environment(model)
        }

        Window("MCP Deck", id: "main") {
            DashboardView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 460)
        }
        .defaultSize(width: 980, height: 620)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Guarantee no health-check process survives the app, even mid-check.
    func applicationWillTerminate(_ notification: Notification) {
        ProcessRegistry.shared.killAll()
    }
}
