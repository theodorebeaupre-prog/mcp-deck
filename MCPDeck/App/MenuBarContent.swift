import SwiftUI
import MCPDeckCore

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.uniqueServers.isEmpty {
            Text("No MCP servers found")
        } else {
            ForEach(model.uniqueServers.prefix(12), id: \.healthKey) { entry in
                let status = model.status(for: entry)
                Button {
                    openMainWindow()
                } label: {
                    // Menu bar menus render plain text; prefix a colored-dot
                    // stand-in so status is readable at a glance.
                    Text("\(statusGlyph(status))  \(entry.name)")
                }
            }
            if model.uniqueServers.count > 12 {
                Text("…and \(model.uniqueServers.count - 12) more")
            }
        }

        Divider()

        Button("Check All Now") {
            Task {
                model.rescan()
                await model.checkAll()
            }
        }

        Button("Open MCP Deck") {
            openMainWindow()
        }
        .keyboardShortcut("o")

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit MCP Deck") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private func statusGlyph(_ status: HealthStatus) -> String {
        switch status {
        case .ok: return "🟢"
        case .authRequired: return "🟡"
        case .error: return "🔴"
        case .timeout: return "🟠"
        case .checking: return "🔵"
        case .unknown: return "⚪️"
        }
    }
}
