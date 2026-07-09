import SwiftUI
import MCPDeckCore

enum ServerListScope: Equatable {
    case all
    case client(ClientID)
}

struct ServerListView: View {
    @Environment(AppModel.self) private var model
    let scope: ServerListScope
    @Binding var selection: String?
    @State private var isRefreshing = false

    var body: some View {
        @Bindable var model = model
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No MCP servers",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("No servers are configured for this scope yet.")
                )
            } else {
                List(selection: $selection) {
                    if case .all = scope, model.groupByServer {
                        ForEach(rows, id: \.healthKey) { entry in
                            ServerRow(entry: entry, showClients: true)
                                .tag(entry.healthKey)
                        }
                    } else {
                        ForEach(groupedByClient, id: \.0) { client, entries in
                            Section(client.displayName) {
                                ForEach(entries, id: \.healthKey) { entry in
                                    ServerRow(entry: entry, showClients: false)
                                        .tag(entry.healthKey)
                                }
                            }
                        }
                    }
                    if !model.issues.isEmpty {
                        Section("Scan warnings") {
                            ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(issue.fileURL.lastPathComponent)
                                            .font(.callout.weight(.medium))
                                        Text(issue.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                }
                                .selectionDisabled()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                if case .all = scope {
                    Picker("Grouping", selection: $model.groupByServer) {
                        Label("By Server", systemImage: "square.stack.3d.up").tag(true)
                        Label("By Client", systemImage: "app.badge").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .help("Group the list by server or by client")
                }
                Button {
                    Task {
                        isRefreshing = true
                        model.rescan()
                        await model.checkAll()
                        isRefreshing = false
                    }
                } label: {
                    Label("Check All", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                .help("Rescan configs and health-check every server")
            }
        }
    }

    private var title: String {
        switch scope {
        case .all: return "All Servers"
        case .client(let id): return id.displayName
        }
    }

    private var rows: [ServerEntry] {
        switch scope {
        case .all: return model.uniqueServers
        case .client(let id): return model.servers(for: id)
        }
    }

    private var groupedByClient: [(ClientID, [ServerEntry])] {
        switch scope {
        case .client(let id):
            return [(id, model.servers(for: id))]
        case .all:
            return ClientID.allCases.compactMap { client in
                let entries = model.servers(for: client)
                return entries.isEmpty ? nil : (client, entries)
            }
        }
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let entry: ServerEntry
    let showClients: Bool

    var body: some View {
        let allEntries = model.entries(forHealthKey: entry.healthKey)
        let isEnabledSomewhere = allEntries.contains(where: \.isEnabled)
        HStack(spacing: 10) {
            StatusDot(status: isEnabledSomewhere ? model.status(for: entry) : .unknown)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isEnabledSomewhere ? .primary : .secondary)
                    if !isEnabledSomewhere {
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(entry.transport.commandLine ?? entry.transport.urlString ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if showClients {
                HStack(spacing: 4) {
                    ForEach(Array(Set(allEntries.map(\.client))).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
                        ClientTag(client: $0)
                    }
                }
            }
            TransportTag(transport: entry.transport)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Check Now") {
                Task { await model.check(entry) }
            }
        }
    }
}
