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
        model("hf:mlx-community/whisper-large-v3-mlx-8bit", "whisper-large-v3-mlx-8bit", .paused,
              size: 1.7, downloaded: 0.6, ram: 2.0, custom: true,
              error: "İndirme durduruldu: diskte en az 10 GB boş kalmalı.",
              repo: "mlx-community/whisper-large-v3-mlx-8bit"),
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
        model("hf:mlx-community/whisper-large-v3-mlx-8bit", "whisper-large-v3-mlx-8bit", .notDownloaded,
              size: 4.4, ram: 2.0, custom: true, repo: "mlx-community/whisper-large-v3-mlx-8bit"),
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
                         copied: true, model: "large-v3", audioSeconds: 5.2, transcribeSeconds: 0.8, language: "tr"),
            HistoryEntry(date: now.addingTimeInterval(-1_800),
                         rawText: "Can you push the fix to the release branch before the demo",
                         editedText: "Can you push the fix to the release branch before the demo?",
                         copied: true, model: "large-v3", audioSeconds: 3.4, transcribeSeconds: 0.6, language: "en"),
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

    /// Settings as a user of `language` would have them.
    static func settings(_ language: AppLanguage = Localizer.shared.language) -> AppSettings {
        var s = AppSettings()
        s.uiLanguage = language
        return s
    }

    static func settingsView(_ settings: Binding<AppSettings>) -> some View {
        SettingsView(settings: settings,
                     microphones: [Microphone(uid: "builtin", name: "MacBook Pro Mikrofonu"),
                                   Microphone(uid: "usb", name: "Shure MV7")],
                     launchAtLogin: launchAtLogin,
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
            case .settings: settingsView(.constant(settings()))
            case .models: modelsView(models, system: system, status: status, selected: selected)
            case .terms: TermsView(terms: terms, actions: termActions)
            case .history: historyView()
            }
        }
    }
}

#Preview("Modeller — tüm durumlar") { PreviewData.window(.models).frame(width: 900, height: 900) }
#Preview("Modeller — az disk") {
    PreviewData.window(.models, models: PreviewData.lowDisk, system: PreviewData.system(freeGB: 14, idleIn: nil),
                       selected: "hf:mlx-community/whisper-large-v3-mlx-8bit")
        .frame(width: 900, height: 760)
}
#Preview("Modeller — motor çalışmıyor") {
    PreviewData.window(.models, models: [], system: nil, status: .failed("Python bulunamadı."))
        .frame(width: 900, height: 500)
}
#Preview("Ayarlar") {
    @Previewable @State var settings = PreviewData.settings()
    PreviewData.settingsView($settings).frame(width: 720, height: 900)
        .onChange(of: settings.uiLanguage) { _, l in Localizer.shared.language = l }
}
#Preview("Ayarlar — English") {
    @Previewable @State var settings = PreviewData.settings(.en)
    PreviewData.settingsView($settings).frame(width: 720, height: 900)
        .onAppear { Localizer.shared.language = .en }
        .onChange(of: settings.uiLanguage) { _, l in Localizer.shared.language = l }
}
#Preview("Geçmiş — English") {
    PreviewData.window(.history).frame(width: 900, height: 660)
        .onAppear { Localizer.shared.language = .en }
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
        PreviewStrings.install()

        for language in AppLanguage.allCases {
            Localizer.shared.language = language
            let sub = dir.appendingPathComponent(language.rawValue, isDirectory: true)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            renderTabs(sub)
        }
        renderLiveSwitch(dir)
        renderStatusIcons(dir)
        print("UI previews written to \(dir.path)")
        let failures = selfCheck()
        print(failures.isEmpty ? "UI self-check: OK" : "UI self-check FAILED:\n" + failures.joined(separator: "\n"))
        let missing = PreviewStrings.missing.sorted()
        if !missing.isEmpty {
            print("Missing English strings (\(missing.count)):\n" + missing.map { "  " + $0 }.joined(separator: "\n"))
        }
        NSApp.terminate(nil)
    }

    private static func renderTabs(_ dir: URL) {
        let w = 900.0
        render(PreviewData.window(.models), "models-all-states", w, 1180, dir)
        render(PreviewData.window(.models), "models-all-states-dark", w, 1180, dir, dark: true)
        render(PreviewData.window(.models), "models-window", w, 660, dir)
        render(PreviewData.window(.models, models: PreviewData.lowDisk,
                                  system: PreviewData.system(freeGB: 14, idleIn: nil), selected: "hf:mlx-community/whisper-large-v3-mlx-8bit"),
               "models-low-disk", w, 1000, dir)
        render(PreviewData.window(.models, models: [], system: nil, status: .failed("Python bulunamadı.")),
               "models-engine-failed", w, 500, dir)
        render(PreviewData.window(.settings), "settings", w, 1300, dir)
        render(PreviewData.window(.settings), "settings-window", w, 660, dir)
        render(PreviewData.window(.settings), "settings-dark", w, 1300, dir, dark: true)
        render(PreviewData.window(.terms), "terms", w, 760, dir)
        render(PreviewData.window(.terms), "terms-dark", w, 760, dir, dark: true)
        render(PreviewData.window(.history), "history", w, 660, dir)
        render(PreviewData.window(.history), "history-dark", w, 660, dir, dark: true)
        render(TermEditor(draft: TermDraft(PreviewData.terms[0]), existing: [], save: { _ in }),
               "term-editor", 440, 420, dir)
        render(TermEditor(draft: TermDraft(original: nil, term: ""), existing: [], save: { _ in }),
               "term-editor-new", 440, 420, dir)
        render(statusMenuMock, "status-menu", 320, 330, dir)
    }

    /// Menu bar menu titles for each status line (NSMenu can't be drawn offscreen).
    private static var statusMenuMock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Dikte'yi aç"))
            Divider()
            ForEach([EngineStatus.starting, .stopped, .failed("Python bulunamadı.")].map(\.display.text),
                    id: \.self) {
                Text($0).foregroundStyle(.secondary)
            }
            Text(L("Model: %@ · %@", "Whisper large-v3", L("Bellekte"))).foregroundStyle(.secondary)
            Text(L("Model: %@ · %@", "Whisper large-v3", L("İndiriliyor %@", Fmt.percent(0.62))))
                .foregroundStyle(.secondary)
            Text(L("Model: %@ · %@", "Whisper large-v3", L("İndirme duraklatıldı"))).foregroundStyle(.secondary)
            Text(L("Model seçilmedi")).foregroundStyle(.secondary)
            Text(L("Modeli şimdi boşalt"))
            Divider()
            HStack { Text(L("Çıkış")); Spacer(); Text(verbatim: "⌘Q").foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Switches the language under a live window (tr → en → tr) to check that everything re-renders.
    private static func renderLiveSwitch(_ dir: URL) {
        Localizer.shared.language = .tr
        let navigation = MainNavigation()
        let view = PreviewLiveWindow(navigation: navigation)
        let (window, hosting) = host(view, 900, 1300, dark: false)
        defer { window.orderOut(nil) }
        settle(hosting)
        snapshot(hosting, window, dir.appendingPathComponent("live-1-settings-tr.png"))
        Localizer.shared.language = .en
        settle(hosting)
        snapshot(hosting, window, dir.appendingPathComponent("live-2-settings-en.png"))
        navigation.tab = .history
        settle(hosting)
        snapshot(hosting, window, dir.appendingPathComponent("live-3-history-en.png"))
        Localizer.shared.language = .tr
        settle(hosting)
        snapshot(hosting, window, dir.appendingPathComponent("live-4-history-tr.png"))
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
        let language = Localizer.shared.language
        defer { Localizer.shared.language = language }
        Localizer.shared.language = .tr
        check(Fmt.gb(10 * PreviewData.gib) == "10\u{00A0}GB", "gb: 10 GB, got \(Fmt.gb(10 * PreviewData.gib))")
        check(Fmt.gb(3_100_000_000) == "2,9\u{00A0}GB", "gb: 2,9 GB, got \(Fmt.gb(3_100_000_000))")
        check(Fmt.percent(0.625) == "%62", "percent: %62, got \(Fmt.percent(0.625))")
        check(Fmt.percent(0.999) == "%99", "percent: %99, got \(Fmt.percent(0.999))")
        check(Fmt.seconds(3.5) == "3,5\u{00A0}sn", "seconds: 3,5 sn, got \(Fmt.seconds(3.5))")
        check(Fmt.int(1234) == "1.234", "int: 1.234, got \(Fmt.int(1234))")
        check(Fmt.countdown(272) == "4:32", "countdown: 4:32")
        Localizer.shared.language = .en
        check(Fmt.gb(3_100_000_000) == "2.9\u{00A0}GB", "gb en: 2.9 GB, got \(Fmt.gb(3_100_000_000))")
        check(Fmt.percent(0.625) == "62%", "percent en: 62%, got \(Fmt.percent(0.625))")
        check(Fmt.seconds(3.5) == "3.5\u{00A0}s", "seconds en: 3.5 s, got \(Fmt.seconds(3.5))")
        check(Fmt.int(1234) == "1,234", "int en: 1,234, got \(Fmt.int(1234))")
        check(Fmt.count(1, one: L("1 kayıt"), other: { L("%@ kayıt", $0) }) == "1 entry", "count en: 1 entry")
        check(Fmt.count(3, one: L("1 kayıt"), other: { L("%@ kayıt", $0) }) == "3 entries", "count en: 3 entries")
        check(L("Dikte'yi aç") == "Open Dikte", "L en: Open Dikte")
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
        let (window, hosting) = host(view, width, height, dark: dark)
        defer { window.orderOut(nil) }
        settle(hosting)
        snapshot(hosting, window, dir.appendingPathComponent(name + ".png"))
    }

    private static func host<V: View>(_ view: V, _ width: CGFloat, _ height: CGFloat,
                                      dark: Bool) -> (NSWindow, NSView) {
        let size = NSSize(width: width, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFrontRegardless()
        return (window, hosting)
    }

    private static func settle(_ hosting: NSView) {
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private static func snapshot(_ hosting: NSView, _ window: NSWindow, _ url: URL) {
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
        try? flat.representation(using: .png, properties: [:])?.write(to: url)
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

/// Live-switch scenario: the real settings binding drives the language like `AppState` does.
private struct PreviewLiveWindow: View {
    @Bindable var navigation: MainNavigation
    @State private var settings = PreviewData.settings(.tr)

    var body: some View {
        MainSplitView(tab: $navigation.tab) { t in
            switch t {
            case .settings: PreviewData.settingsView($settings)
            case .models: PreviewData.modelsView()
            case .terms: TermsView(terms: PreviewData.terms, actions: PreviewData.termActions)
            case .history: PreviewData.historyView()
            }
        }
    }
}

/// Renderer-only English fallback: until the lead merges `i18n/*.json` into the String Catalog,
/// the built `en.lproj` lacks most keys, so lookups that come back unchanged are answered from
/// `app/dikte/i18n/ui.json` in the repo. Not used by the app itself.
enum PreviewStrings {
    nonisolated static let en: [String: String] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("i18n/ui.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            print("PreviewStrings: could not read \(url.path)")
            return [:]
        }
        return dict
    }()

    static var missing: Set<String> = []

    static func install() {
        guard let original = class_getInstanceMethod(Bundle.self, #selector(Bundle.localizedString(forKey:value:table:))),
              let fallback = class_getInstanceMethod(Bundle.self, #selector(Bundle.dikte_previewLocalizedString(forKey:value:table:)))
        else { return }
        _ = en
        method_exchangeImplementations(original, fallback)
    }
}

extension Bundle {
    /// Swapped with `localizedString(forKey:value:table:)` by `PreviewStrings.install()`;
    /// the call below therefore reaches the original implementation.
    @objc nonisolated dynamic func dikte_previewLocalizedString(forKey key: String, value: String?,
                                                                table: String?) -> String {
        let s = dikte_previewLocalizedString(forKey: key, value: value, table: table)
        guard s == key || s == value, bundlePath.hasSuffix("/en.lproj") else { return s }
        if let t = PreviewStrings.en[key] { return t }
        if Thread.isMainThread { MainActor.assumeIsolated { _ = PreviewStrings.missing.insert(key) } }
        return s
    }
}
#endif
