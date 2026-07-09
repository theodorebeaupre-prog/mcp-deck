import SwiftUI
import Observation
import MCPDeckCore

struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

@MainActor
@Observable
final class LogsModel {
    private(set) var files: [LogFile] = []
    private(set) var lines: [LogLine] = []
    var filter = ""
    var selectedFile: LogFile? {
        didSet {
            guard oldValue != selectedFile else { return }
            startTailing()
        }
    }

    @ObservationIgnored private var tailTask: Task<Void, Never>?
    @ObservationIgnored private var nextLineID = 0
    private static let maxLines = 2000

    var filteredLines: [LogLine] {
        guard !filter.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    func refreshFiles() {
        files = LogDiscovery.claudeDesktopLogs()
        if selectedFile == nil || !files.contains(selectedFile!) {
            selectedFile = files.first
        }
    }

    func stop() {
        tailTask?.cancel()
        tailTask = nil
    }

    private func startTailing() {
        tailTask?.cancel()
        lines.removeAll()
        guard let file = selectedFile else { return }
        let tailer = LogTailer(url: file.url)
        tailTask = Task { [weak self] in
            for await line in tailer.lines() {
                guard let self, !Task.isCancelled else { break }
                self.append(line)
            }
        }
    }

    private func append(_ text: String) {
        lines.append(LogLine(id: nextLineID, text: text))
        nextLineID += 1
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }
}

/// Middle column: the discovered Claude Desktop MCP log files.
struct LogFileListView: View {
    @Bindable var logsModel: LogsModel

    var body: some View {
        Group {
            if logsModel.files.isEmpty {
                ContentUnavailableView(
                    "No MCP logs",
                    systemImage: "text.alignleft",
                    description: Text("Claude Desktop hasn't written any MCP logs yet.")
                )
            } else {
                List(logsModel.files, selection: Binding(
                    get: { logsModel.selectedFile?.id },
                    set: { id in logsModel.selectedFile = logsModel.files.first { $0.id == id } }
                )) { file in
                    Label {
                        Text(file.displayName)
                    } icon: {
                        Image(systemName: file.serverName == nil ? "text.alignleft" : "server.rack")
                    }
                    .tag(file.id)
                }
            }
        }
        .navigationTitle("Logs")
        .task {
            logsModel.refreshFiles()
        }
        .toolbar {
            Button {
                logsModel.refreshFiles()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan the log directory")
        }
    }
}

/// Detail column: live tail of the selected log file.
struct LogLinesView: View {
    @Bindable var logsModel: LogsModel

    var body: some View {
        Group {
            if logsModel.selectedFile == nil {
                ContentUnavailableView(
                    "Select a log",
                    systemImage: "text.alignleft",
                    description: Text("Pick a log file to follow it live.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(logsModel.filteredLines) { line in
                                Text(line.text)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(12)
                    }
                    .background(.background)
                    .onChange(of: logsModel.filteredLines.last?.id) { _, lastID in
                        if let lastID {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle(logsModel.selectedFile?.displayName ?? "Logs")
        .searchable(text: $logsModel.filter, placement: .toolbar, prompt: "Filter lines")
    }
}
