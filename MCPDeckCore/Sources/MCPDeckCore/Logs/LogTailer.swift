import Foundation

/// Tails a log file like `tail -f`: emits an initial backfill, then every
/// appended line, surviving truncation and rotation (offset beyond file size
/// → reopen from the start). Watching combines a vnode DispatchSource with a
/// low-frequency poll, because vnode events alone miss writes through
/// hard-link rotations.
public final class LogTailer: @unchecked Sendable {
    private let url: URL
    private let backfillBytes: UInt64
    private let queue = DispatchQueue(label: "com.theodorebeaupre.MCPDeck.LogTailer")
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var partialLine = Data()
    private var emit: ((String) -> Void)?

    public init(url: URL, backfillBytes: UInt64 = 64 * 1024) {
        self.url = url
        self.backfillBytes = backfillBytes
    }

    deinit {
        stopLocked()
    }

    /// Lines appended to the file, starting with up to `backfillBytes` of
    /// existing content. Finishing the iteration stops all watching.
    public func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                self.emit = { continuation.yield($0) }
                self.openAndBackfill()
                self.startWatching()
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.stopLocked() }
            }
        }
    }

    // MARK: Private (all on `queue`)

    private func openAndBackfill() {
        guard let newHandle = try? FileHandle(forReadingFrom: url) else { return }
        handle = newHandle
        let size = (try? newHandle.seekToEnd()) ?? 0
        offset = size > backfillBytes ? size - backfillBytes : 0
        try? newHandle.seek(toOffset: offset)
        if offset > 0 {
            // Skip the probably-partial first line of the backfill window.
            readAvailableLines().dropFirst().forEach { emit?($0) }
        } else {
            readAvailableLines().forEach { emit?($0) }
        }
    }

    private func startWatching() {
        if let handle {
            let vnodeSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: handle.fileDescriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue
            )
            vnodeSource.setEventHandler { [weak self] in self?.drain() }
            vnodeSource.resume()
            source = vnodeSource
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        pollTimer = timer
    }

    private func drain() {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil

        // Rotated or truncated: reopen from the beginning of the new file.
        if handle == nil || (fileSize ?? 0) < offset {
            source?.cancel()
            source = nil
            try? handle?.close()
            handle = nil
            offset = 0
            partialLine.removeAll()
            guard let reopened = try? FileHandle(forReadingFrom: url) else { return }
            handle = reopened
            let vnodeSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: reopened.fileDescriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue
            )
            vnodeSource.setEventHandler { [weak self] in self?.drain() }
            vnodeSource.resume()
            source = vnodeSource
        }

        readAvailableLines().forEach { emit?($0) }
    }

    private func readAvailableLines() -> [String] {
        guard let handle else { return [] }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)

        partialLine.append(data)
        var lines: [String] = []
        while let newlineIndex = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = partialLine[partialLine.startIndex..<newlineIndex]
            partialLine.removeSubrange(partialLine.startIndex...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    private func stopLocked() {
        source?.cancel()
        source = nil
        pollTimer?.cancel()
        pollTimer = nil
        try? handle?.close()
        handle = nil
        emit = nil
    }
}
