import SwiftUI
import MCPDeckCore

struct ServerDetailView: View {
    @Environment(AppModel.self) private var model
    let healthKey: String
    @State private var revealedEnvKeys: Set<String> = []

    private var entries: [ServerEntry] { model.entries(forHealthKey: healthKey) }
    private var primary: ServerEntry? { entries.first }

    var body: some View {
        if let primary {
            content(primary)
        } else {
            ContentUnavailableView("Server not found", systemImage: "questionmark")
        }
    }

    private func content(_ primary: ServerEntry) -> some View {
        let status = model.status(for: primary)
        let report = model.report(for: primary)

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(primary, status: status)

                if let detail = status.detailText {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(status.isProblem ? .red : .secondary)
                        .textSelection(.enabled)
                }

                section("Configuration") {
                    configurationBody(primary)
                }

                if case .stdio(_, _, let env) = primary.transport, !env.isEmpty {
                    section("Environment") {
                        environmentBody(env)
                    }
                }

                section("Used by") {
                    usedByBody
                }

                section("Tools") {
                    toolsBody(report: report, status: status)
                }

                if let report {
                    Text("Last checked \(report.checkedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(primary.name)
        .toolbar {
            Button {
                Task { await model.check(primary) }
            } label: {
                Label("Check Now", systemImage: "stethoscope")
            }
            .disabled(status == .checking)
            .help("Run a health check on this server")
        }
    }

    // MARK: Sections

    private func header(_ entry: ServerEntry, status: HealthStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.title2.weight(.semibold))
                    TransportTag(transport: entry.transport)
                }
                if let info = model.report(for: entry)?.serverInfo {
                    Text("\(info.name)\(info.version.map { " \($0)" } ?? "")\(info.protocolVersion.map { " · MCP \($0)" } ?? "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusBadge(status: status)
        }
    }

    @ViewBuilder
    private func configurationBody(_ entry: ServerEntry) -> some View {
        let text = entry.transport.commandLine ?? entry.transport.urlString ?? ""
        HStack(alignment: .top) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func environmentBody(_ env: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(env.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.callout.monospaced())
                    Spacer()
                    Text(revealedEnvKeys.contains(key) ? (env[key] ?? "") : String(repeating: "•", count: 8))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        if revealedEnvKeys.contains(key) {
                            revealedEnvKeys.remove(key)
                        } else {
                            revealedEnvKeys.insert(key)
                        }
                    } label: {
                        Image(systemName: revealedEnvKeys.contains(key) ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealedEnvKeys.contains(key) ? "Hide value" : "Reveal value")
                }
            }
        }
    }

    private var usedByBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.client.displayName)
                            .font(.callout.weight(.medium))
                        Text(entry.location.scopeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.location.fileURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal config file in Finder")
                    Toggle("Enabled", isOn: Binding(
                        get: { entry.isEnabled },
                        set: { model.setEnabled($0, entry: entry) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(entry.isEnabled
                          ? "Disable in \(entry.client.displayName) (moves to _disabled_mcpServers)"
                          : "Re-enable in \(entry.client.displayName)")
                }
            }
        }
    }

    @ViewBuilder
    private func toolsBody(report: HealthReport?, status: HealthStatus) -> some View {
        if let report, !report.tools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.tools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.callout.monospaced().weight(.medium))
                        if let summary = tool.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        } else if case .ok = status {
            Text("The server reported no tools.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("Run a health check to list this server's tools.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            body()
        }
    }
}
