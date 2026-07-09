import SwiftUI
import MCPDeckCore

@main
struct MCPDeckApp: App {
    var body: some Scene {
        MenuBarExtra("MCP Deck", systemImage: "square.stack.3d.up") {
            Text("MCP Deck \(MCPDeckCoreInfo.version)")
        }
    }
}
