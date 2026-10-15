import Foundation

/// Appends engine stderr (and stray stdout) to `logs/engine.log`; rotates to `engine.log.1` at ~5 MB.
/// Thread-safe: written from pipe readability handlers on background queues.
nonisolated final class EngineLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mehmetcaykara.dikte.engine-log")
    private let url: URL
    private let maxBytes: UInt64
    private var handle: FileHandle?

    init(url: URL, maxBytes: UInt64 = 5 * 1024 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { self.write(data) }
    }

    func note(_ line: String) {
        append(Data("[\(Date().formatted(.iso8601))] dikte: \(line)\n".utf8))
    }

    private func write(_ data: Data) {
        let fm = FileManager.default
        if handle == nil {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { return }
        try? handle.write(contentsOf: data)
        if let size = try? handle.offset(), size > maxBytes {
            try? handle.close()
            self.handle = nil
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
    }
}
