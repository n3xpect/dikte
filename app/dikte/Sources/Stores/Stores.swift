import Foundation
import os

// Shared persistence helpers for the JSON stores (SettingsStore, HistoryStore, TermsStore).

enum StoreJSON {
    static let log = Logger(subsystem: "com.mehmetcaykara.dikte", category: "stores")

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? Date(s, strategy: .iso8601) { return date }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Geçersiz tarih: \(s)")
        }
        return d
    }()

    /// Reads `url`. Missing file → nil. Unreadable/corrupt file → renamed to `<name>.bak`, nil.
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            log.error("Corrupt \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let bak = url.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? fm.moveItem(at: url, to: bak)
            return nil
        }
    }

    /// Pretty-printed, atomic write.
    static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Save \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension String {
    /// Turkish-aware case fold used for term matching ("İ"→"i", "I"→"ı"; ı and i treated as equal).
    var turkishFolded: String {
        lowercased(with: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
