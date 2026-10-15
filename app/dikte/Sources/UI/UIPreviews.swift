#if DEBUG
import AppKit
import SwiftUI

// Fake data, #Previews and a PNG renderer for the main window and menu bar icon.
// Render: `dikte.app/Contents/MacOS/dikte --render-ui-previews <dir>` (Debug builds only).

enum PreviewData {
    static let gib: Int64 = 1_073_741_824

    static func model(_ id: String, _ label: String, _ state: ModelState, size: Double?, downloaded: Double? = nil,
                      ram: Double? = nil, note: String = "", recommended: Bool = false, custom: Bool = false,
                      progress: Double? = nil, error: String? = nil, repo: String? = nil) -> ModelInfo {
        let sizeBytes = size.map { Int64($0 * Double(gib)) }
        let downloadedBytes = downloaded.map { Int64($0 * Double(gib)) }
            ?? ([.onDisk, .loading, .loaded].contains(state) ? sizeBytes ?? 0 : 0)
        return ModelInfo(id: id, label: label, repo: repo ?? "mlx-community/\(id)", kind: "mlx-whisper",
                         custom: custom, recommended: recommended, note: note, sizeBytes: sizeBytes,
                         downloadedBytes: downloadedBytes, ramBytes: ram.map { Int64($0 * Double(gib)) },
                         state: state, progress: progress, error: error)
    }

    /// Every state at once (not realistic — only one model can be loading/loaded).
    static let allStates: [ModelInfo] = [
        model("large-v3", "Whisper large-v3", .loaded, size: 2.9, ram: 3.5,
              note: "WER 7,9% · terim 96% · ~0,8 sn", recommended: true, repo: "mlx-community/whisper-large-v3-mlx"),
        model("large-v3-turbo", "Whisper large-v3 turbo", .downloading, size: 1.5, downloaded: 0.93, ram: 1.9,
              note: "Daha hızlı, biraz daha az isabetli", progress: 0.62, repo: "mlx-community/whisper-large-v3-turbo"),
        model("qwen3-asr", "Qwen3-ASR 1.7B", .paused, size: 4.4, downloaded: 1.2, ram: 5.2,
              note: "Deneysel", error: "İndirme durduruldu: diskte en az 10 GB boş kalmalı.",
              repo: "mlx-community/Qwen3-ASR-1.7B"),
        model("hf:mlx-community/whisper-medium-mlx", "whisper-medium-mlx", .onDisk, size: 1.4, ram: 1.8,
              custom: true, repo: "mlx-community/whisper-medium-mlx"),
        model("small", "Whisper small", .loading, size: 0.45, ram: 0.6, note: "Küçük ve hızlı",
              repo: "mlx-community/whisper-small-mlx"),
        model("hf:someone/huge-asr", "huge-asr", .notDownloaded, size: 420, ram: 60, custom: true,
              repo: "someone/huge-asr"),
    ]

    /// Low disk: the selected model can't be downloaded.
    static let lowDisk: [ModelInfo] = [
        model("large-v3", "Whisper large-v3", .onDisk, size: 2.9, ram: 3.5,
              note: "WER 7,9% · terim 96% · ~0,8 sn", recommended: true, repo: "mlx-community/whisper-large-v3-mlx"),
        model("large-v3-turbo", "Whisper large-v3 turbo", .notDownloaded, size: 1.5, ram: 1.9,
              note: "Daha hızlı, biraz daha az isabetli", repo: "mlx-community/whisper-large-v3-turbo"),
        model("qwen3-asr", "Qwen3-ASR 1.7B", .notDownloaded, size: 4.4, ram: 5.2, note: "Deneysel",
              repo: "mlx-community/Qwen3-ASR-1.7B"),
        model("hf:mlx-community/whisper-medium-mlx", "whisper-medium-mlx", .onDisk, size: 1.4, ram: 1.8,
              custom: true, repo: "mlx-community/whisper-medium-mlx"),
    ]

    static func system(freeGB: Double, idleIn: TimeInterval? = 272) -> SystemInfo {
        SystemInfo(diskFreeBytes: Int64(freeGB * Double(gib)), minFreeBytes: 10 * gib,
                   ramTotalBytes: 24 * gib, ramAvailableBytes: 13 * gib, idleUnloadS: 300,
                   idleUnloadAt: idleIn.map { Date().timeIntervalSince1970 + $0 }, selectedModel: "large-v3")
    }

    static let terms: [Term] = [
        Term(term: "branch", accept: ["branch", "Branch"], fix: ["brenç", "branş"]),
        Term(term: "commit", accept: ["commit"], fix: ["komit", "kommit"]),
        Term(term: "pull request", accept: ["PR"], fix: ["pul rikuest", "pull rikuest"]),
        Term(term: "Kubernetes", fix: ["kubernetis", "kubernetiz"]),
        Term(term: "deploy", accept: ["deploy", "deployment"], fix: ["diploy"]),
        Term(term: "SwiftUI", fix: ["svift yu ay"]),
    ]

    static let history: [HistoryEntry] = {
        let now = Date()
        return [
            HistoryEntry(date: now.addingTimeInterval(-120),
                         rawText: "Yeni brenç açıp değişiklikleri komit ettim, şimdi pul rikuest açıyorum.",
                         editedText: "Yeni branch açıp değişiklikleri commit ettim, şimdi pull request açıyorum.",
                         copied: true, model: "large-v3", audioSeconds: 5.2, transcribeSeconds: 0.8),
            HistoryEntry(date: now.addingTimeInterval(-3_600),
                         rawText: "Toplantıyı yarın saat üçe alalım mı acaba",
                         editedText: "Toplantıyı yarın saat 15.00'e alalım mı?",
                         copied: true, model: "large-v3", audioSeconds: 3.1, transcribeSeconds: 0.6),
            HistoryEntry(date: now.addingTimeInterval(-86_400),
                         rawText: "Kubernetis üzerinde diploy sırasında ışık gibi hızlı bir hata aldık.",
                         editedText: "Kubernetes üzerinde deploy sırasında ışık gibi hızlı bir hata aldık.",
                         copied: false, model: "large-v3-turbo", audioSeconds: 6.4, transcribeSeconds: 0.5),
            HistoryEntry(date: now.addingTimeInterval(-90_000),
                         rawText: "Şu dosyayı İstanbul ofisine gönderir misin",
                         editedText: "Şu dosyayı İstanbul ofisine gönderir misin",
                         copied: true, model: "large-v3", audioSeconds: 2.7, transcribeSeconds: 0.7),
        ]
    }()

    static let labels = ["large-v3": "Whisper large-v3", "large-v3-turbo": "Whisper large-v3 turbo"]

    static let actions = ModelActions(
        select: { _ in }, download: { _ in }, cancelDownload: { _ in }, delete: { _ in }, load: { _ in },
        unload: {}, addCustom: { _ in throw EngineAPIError(error: "repo_not_found", message: "Depo bulunamadı.") },
        removeCustom: { _ in }, restartEngine: {}
    )

    static let launchAtLogin = LaunchAtLogin(status: { .notRegistered }, setEnabled: { _ in })
    static let termActions = TermActions(upsert: { _ in }, delete: { _ in })

    // MARK: Scenario views

    static func modelsView(_ models: [ModelInfo] = allStates, system: SystemInfo? = system(freeGB: 415),
                           status: EngineStatus = .running(port: 1), selected: String = "large-v3") -> some View {
        ModelsView(status: status, models: models, system: system, selectedModel: selected,
                   minFreeDiskGB: 10, actions: actions)
    }

    static func settingsView(_ settings: Binding<AppSettings>) -> some View {
        SettingsView(settings: settings,
                     microphones: [Microphone(uid: "builtin", name: "MacBook Pro Mikrofonu"),
                                   Microphone(uid: "usb", name: "Shure MV7")],
                     terms: terms, termActions: termActions, launchAtLogin: launchAtLogin,
                     engineStatus: .running(port: 1),
                     dataDir: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/dikte"))
    }

    static func historyView(selectFirst: Bool = true) -> some View {
        HistoryView(entries: history, modelLabel: { labels[$0] ?? $0 }, delete: { _ in }, clear: {},
                    selection: selectFirst ? history[0].id : nil)
    }

    static func window(_ tab: MainTab, models: [ModelInfo] = allStates, system: SystemInfo? = system(freeGB: 415),
                       status: EngineStatus = .running(port: 1), selected: String = "large-v3") -> some View {
        MainSplitView(tab: .constant(tab)) { t in
            switch t {
            case .settings: settingsView(.constant(AppSettings()))
            case .models: modelsView(models, system: system, status: status, selected: selected)
            case .history: historyView()
            }
        }
    }
}

#Preview("Modeller — tüm durumlar") { PreviewData.window(.models).frame(width: 900, height: 900) }
#Preview("Modeller — az disk") {
    PreviewData.window(.models, models: PreviewData.lowDisk, system: PreviewData.system(freeGB: 14, idleIn: nil),
                       selected: "qwen3-asr")
        .frame(width: 900, height: 760)
}
#Preview("Modeller — motor çalışmıyor") {
    PreviewData.window(.models, models: [], system: nil, status: .failed("Python bulunamadı."))
        .frame(width: 900, height: 500)
}
#Preview("Ayarlar") {
    @Previewable @State var settings = AppSettings()
    PreviewData.settingsView($settings).frame(width: 720, height: 900)
}
#Preview("Geçmiş") { PreviewData.window(.history).frame(width: 900, height: 660) }
#Preview("Terim düzenle") {
    TermEditor(draft: TermDraft(PreviewData.terms[0]), existing: [], save: { _ in })
}

@MainActor
enum UIPreviewRenderer {
    static func renderAllAndQuit() {
        let args = ProcessInfo.processInfo.arguments
        let dir: URL = {
            if let i = args.firstIndex(of: "--render-ui-previews"), i + 1 < args.count {
                return URL(fileURLWithPath: args[i + 1], isDirectory: true)
            }
            return FileManager.default.temporaryDirectory.appendingPathComponent("dikte-ui-previews")
        }()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let w = 900.0
        render(PreviewData.window(.models), "models-all-states", w, 1180, dir)
        render(PreviewData.window(.models), "models-all-states-dark", w, 1180, dir, dark: true)
        render(PreviewData.window(.models), "models-window", w, 660, dir)
        render(PreviewData.window(.models, models: PreviewData.lowDisk,
                                  system: PreviewData.system(freeGB: 14, idleIn: nil), selected: "qwen3-asr"),
               "models-low-disk", w, 1000, dir)
        render(PreviewData.window(.models, models: [], system: nil, status: .failed("Python bulunamadı.")),
               "models-engine-failed", w, 500, dir)
        render(PreviewData.window(.settings), "settings", w, 1300, dir)
        render(PreviewData.window(.settings), "settings-window", w, 660, dir)
        render(PreviewData.window(.settings), "settings-dark", w, 1300, dir, dark: true)
        render(PreviewData.window(.history), "history", w, 660, dir)
        render(PreviewData.window(.history), "history-dark", w, 660, dir, dark: true)
        render(TermEditor(draft: TermDraft(PreviewData.terms[0]), existing: [], save: { _ in }),
               "term-editor", 440, 420, dir)
        renderStatusIcons(dir)
        print("UI previews written to \(dir.path)")
        let failures = selfCheck()
        print(failures.isEmpty ? "UI self-check: OK" : "UI self-check FAILED:\n" + failures.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// Pure-logic checks for the helpers (search folding, diff, formatting, repo parsing).
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        check(TurkishSearch.matches("isik", ["Işık gibi"]), "search: isik ~ Işık")
        check(TurkishSearch.matches("ISTANBUL", ["İstanbul ofisi"]), "search: ISTANBUL ~ İstanbul")
        check(TurkishSearch.matches("şimdi pull", ["Şimdi PULL request"]), "search: multi-token")
        check(!TurkishSearch.matches("brenç", ["branch"]), "search: no false match")
        check(WordDiff.diff("a b c", "a x c") == [.same("a"), .removed("b"), .added("x"), .same("c")], "diff: replace")
        check(WordDiff.diff("", "a b") == [.added("a"), .added("b")], "diff: from empty")
        check(WordDiff.diff("a b", "a b") == [.same("a"), .same("b")], "diff: equal")
        check(Fmt.gb(10 * PreviewData.gib) == "10 GB", "gb: 10 GB, got \(Fmt.gb(10 * PreviewData.gib))")
        check(Fmt.gb(3_100_000_000) == "2,9 GB", "gb: 2,9 GB, got \(Fmt.gb(3_100_000_000))")
        check(Fmt.percent(0.625) == "%62", "percent: %62")
        check(Fmt.countdown(272) == "4:32", "countdown: 4:32")
        check(ModelsView.normalizedRepo("https://huggingface.co/mlx-community/whisper-x/tree/main")
              == "mlx-community/whisper-x", "repo: url")
        check(ModelsView.normalizedRepo("org/name") == "org/name", "repo: plain")
        check(ModelsView.normalizedRepo("justname") == nil, "repo: invalid")
        check(DiskCheck.known(needed: 4 * PreviewData.gib, free: 14 * PreviewData.gib, minFree: 10 * PreviewData.gib)
              .allowsDownload, "disk: exactly min free allowed")
        check(!DiskCheck.known(needed: 5 * PreviewData.gib, free: 14 * PreviewData.gib, minFree: 10 * PreviewData.gib)
              .allowsDownload, "disk: below min free blocked")
        check(TermDraft.list(" a, b ,, a,c ") == ["a", "b", "c"], "terms: comma list")
        return failures
    }

    private static func render<V: View>(_ view: V, _ name: String, _ width: CGFloat, _ height: CGFloat,
                                        _ dir: URL, dark: Bool = false) {
        let size = NSSize(width: width, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFrontRegardless()
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // Materials render transparent offscreen: flatten onto the window background.
        guard let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
                                          pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) else { return }
        flat.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flat)
        window.appearance?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? flat.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    /// Menu bar icons on light and dark bars, 4× scale.
    private static func renderStatusIcons(_ dir: URL) {
        let icons = StatusIcon.allCases
        let cell = NSSize(width: 28, height: 24)
        let size = NSSize(width: cell.width * CGFloat(icons.count), height: cell.height * 2)
        let scale = 4.0
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                let y = CGFloat(1 - row) * cell.height
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: 0, y: y, width: size.width, height: cell.height).fill()
                for (i, icon) in icons.enumerated() {
                    var image = icon.image
                    if image.isTemplate { image = tinted(image, .labelColor) }
                    let r = NSRect(x: CGFloat(i) * cell.width + (cell.width - image.size.width) / 2,
                                   y: y + (cell.height - image.size.height) / 2,
                                   width: image.size.width, height: image.size.height)
                    image.draw(in: r, from: .zero, operation: .sourceOver, fraction: icon == .starting ? 0.5 : 1)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("status-icons.png"))
    }

    private static func tinted(_ template: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
#endif
