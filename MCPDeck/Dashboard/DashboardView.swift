import SwiftUI
import MCPDeckCore

enum SidebarItem: Hashable {
    case allServers
    case client(ClientID)
    case logs
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebarSelection: SidebarItem? = .allServers
    @State private var selectedServerKey: String?
    @State private var logsModel = LogsModel()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            detailColumn
        }
        .alert(
            "Config change failed",
            isPresented: Binding(
                get: { model.lastActionError != nil },
                set: { if !$0 { model.lastActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastActionError ?? "")
        }
    }

    // MARK: Columns

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Servers") {
                Label("All Servers", systemImage: "square.stack.3d.up")
                    .badge(model.uniqueServers.count)
                    .tag(SidebarItem.allServers)
                ForEach(model.clients) { client in
                    Label(client.id.displayName, systemImage: symbol(for: client.id))
                        .badge(client.isInstalled ? client.serverCount : 0)
                        .foregroundStyle(client.isInstalled ? .primary : .tertiary)
                        .tag(SidebarItem.client(client.id))
                }
            }
            Section("Activity") {
                Label("Logs", systemImage: "text.alignleft")
                    .tag(SidebarItem.logs)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch sidebarSelection {
        case .logs:
            LogFileListView(logsModel: logsModel)
        case .client(let clientID):
            if model.clients.first(where: { $0.id == clientID })?.isInstalled == false {
                ContentUnavailableView(
                    "\(clientID.displayName) not detected",
                    systemImage: "questionmark.folder",
                    description: Text("No configuration folder was found for this client.")
                )
            } else {
                ServerListView(
                    scope: .client(clientID),
                    selection: $selectedServerKey
                )
            }
        default:
            ServerListView(scope: .all, selection: $selectedServerKey)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch sidebarSelection {
        case .logs:
            LogLinesView(logsModel: logsModel)
        default:
            if let key = selectedServerKey, !model.entries(forHealthKey: key).isEmpty {
                ServerDetailView(healthKey: key)
            } else {
                ContentUnavailableView(
                    "Select a server",
                    systemImage: "square.stack.3d.up",
                    description: Text("Pick a server from the list to inspect it.")
                )
            }
        }
    }

    private func symbol(for client: ClientID) -> String {
        switch client {
        case .claudeDesktop: return "sparkle"
        case .claudeCode: return "terminal"
        case .cursor: return "cursorarrow"
        }
    }
}
