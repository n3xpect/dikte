import Foundation

enum Paths {
    /// ~/Library/Application Support/dikte (override: env `DIKTE_DATA_DIR`, for tests)
    static let dataDir: URL = {
        let dir: URL
        if let env = ProcessInfo.processInfo.environment["DIKTE_DATA_DIR"], !env.isEmpty {
            dir = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("dikte", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var settingsFile: URL { dataDir.appendingPathComponent("settings.json") }
    static var historyFile: URL { dataDir.appendingPathComponent("history.json") }
    static var termsFile: URL { dataDir.appendingPathComponent("terms.json") }
    static var modelsDir: URL { dataDir.appendingPathComponent("models", isDirectory: true) }
    static var logsDir: URL { dataDir.appendingPathComponent("logs", isDirectory: true) }

    /// Where the Python engine lives:
    /// - packaged app: `dikte.app/Contents/Resources/engine` (contains `python/` + `dikte_engine/`)
    /// - dev build: `app/engine` in the repo (Info.plist `DikteDevEngineDir`), using its `.venv`
    /// - override: env `DIKTE_ENGINE_DIR`
    static var engineDir: URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["DIKTE_ENGINE_DIR"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine", isDirectory: true),
           fm.fileExists(atPath: res.path) {
            return res
        }
        if let dev = Bundle.main.object(forInfoDictionaryKey: "DikteDevEngineDir") as? String,
           !dev.isEmpty, fm.fileExists(atPath: dev) {
            return URL(fileURLWithPath: dev, isDirectory: true).standardizedFileURL
        }
        return nil
    }

    /// Python interpreter for the engine: bundled `python/bin/python3`, else dev `.venv/bin/python`.
    static var enginePython: URL? {
        guard let dir = engineDir else { return nil }
        let fm = FileManager.default
        for rel in ["python/bin/python3", ".venv/bin/python"] {
            let url = dir.appendingPathComponent(rel)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
