#if DEBUG
import Foundation

/// Pure-logic checks for `DeliveryService.entries(...)` and the `AppSettings` target list; run
/// with the UI self-check (`dikte --render-ui-previews <dir>`). Returns the failures.
enum DeliverySelfCheck {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append("delivery: " + what) } }

        func app(_ id: String, _ name: String, running: Bool = true) -> TargetApp {
            TargetApp(bundleID: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"), isRunning: running)
        }
        let running = [
            app("dev.zed.Zed", "Zed"), app("com.todesktop.cursor", "Cursor"), app("com.example.calisma", "Çalışma"),
            app("com.apple.Safari", "Safari"), app("com.apple.Terminal", "Terminal"), app("com.apple.mail", "Mail"),
            app("com.tinyspeck.slackmacgap", "Slack"), app("com.apple.dt.Xcode", "Xcode"),
            app("com.apple.Safari", "Safari"),  // duplicate on purpose
        ]
        let installed = [app("com.apple.TextEdit", "TextEdit", running: false),
                         app("com.apple.Notes", "Notlar", running: false)]
        let resolve: (String) -> TargetApp? = { id in installed.first { $0.bundleID == id } }
        let tr = AppLanguage.tr.locale, en = AppLanguage.en.locale
        let clip = AppSettings.clipboard

        func entries(_ targets: [String], _ apps: [TargetApp] = running, locale: Locale = tr,
                     limit: Int = 5) -> (visible: [DeliveryEntry], more: [DeliveryEntry]) {
            DeliveryService.entries(targets: targets, running: apps, locale: locale, limit: limit, resolve: resolve)
        }
        func names(_ e: [DeliveryEntry]) -> [String] { e.map { $0.app?.name ?? "<pano>" } }

        // Fresh install: the clipboard is the default; 5 others visible (Turkish A–Z), rest in more.
        var r = entries([clip])
        check(names(r.visible) == ["<pano>", "Cursor", "Çalışma", "Mail", "Safari", "Slack"],
              "clipboard default visible \(names(r.visible))")
        check(names(r.more) == ["Terminal", "Xcode", "Zed"], "clipboard default more \(names(r.more))")
        check(r.visible[0].role == .defaultTarget && r.visible[0].app == nil && !r.visible[0].isFavorite
              && r.visible[0].shortcut == nil && r.visible[0].id == clip && r.visible[0].isMovable, "clipboard row")
        check(r.visible.dropFirst().map(\.shortcut) == [1, 2, 3, 4, 5], "⌘ numbering \(r.visible.map(\.shortcut))")
        check(r.more.allSatisfy { $0.shortcut == nil && $0.role == .other && !$0.isMovable }, "more rows")

        // The user's order is kept; the first is the default, the clipboard can be anywhere.
        r = entries(["com.todesktop.cursor", "com.apple.TextEdit", clip, "com.apple.Notes"])
        check(names(r.visible) == ["Cursor", "TextEdit", "<pano>", "Notlar", "Çalışma", "Mail", "Safari", "Slack",
                                   "Terminal"], "user order \(names(r.visible))")
        check(r.visible[0].role == .defaultTarget && r.visible[0].isFavorite, "app default")
        check(r.visible[1].role == .favorite && r.visible[1].app?.isRunning == false, "closed app listed")
        check(r.visible[2].role == .favorite && r.visible[2].app == nil && r.visible[2].shortcut == 2,
              "clipboard as ⌘2")
        check(r.visible.filter { $0.id == "com.todesktop.cursor" }.count == 1, "listed app not among others")
        check(r.visible.dropFirst().map(\.shortcut) == Array(1...8).map(Optional.some), "⌘ numbering in order")
        check(names(r.more) == ["Xcode", "Zed"], "more after the list \(names(r.more))")

        // Apps that aren't installed are skipped: the next one becomes the default.
        r = entries(["com.gone.app", "com.gone.too", "com.apple.TextEdit", clip])
        check(r.visible[0].app?.name == "TextEdit" && r.visible[0].role == .defaultTarget, "uninstalled first skipped")
        check(names(r.visible).prefix(2) == ["TextEdit", "<pano>"], "uninstalled skipped \(names(r.visible))")

        // Missing clipboard / duplicates are normalised.
        r = entries(["com.apple.TextEdit", "com.apple.TextEdit"])
        check(names(r.visible).prefix(3) == ["TextEdit", "<pano>", "Cursor"], "normalised \(names(r.visible))")

        // Limits.
        r = entries([clip], limit: 0)
        check(r.visible.count == 1 && r.more.count == 8, "limit 0 → all in more (\(r.visible.count), \(r.more.count))")
        r = entries([clip], limit: 9)
        check(r.visible.count == 9 && r.more.isEmpty, "limit 9 → all visible")
        r = entries([clip], limit: -3)
        check(r.visible.count == 1, "negative limit")

        // ⌘ numbering stops at 9.
        let many = (0..<12).map { app("com.example.app\($0)", String(format: "App %02d", $0)) }
        r = DeliveryService.entries(targets: many.map(\.bundleID), running: [], locale: tr, limit: 5,
                                    resolve: { id in many.first { $0.bundleID == id } })
        check(r.visible.count == 13, "12 apps + clipboard all visible")
        check(r.visible[9].shortcut == 9 && r.visible[10].shortcut == nil, "no shortcut beyond ⌘9")

        // Locale ordering of the other apps: Ç after C in Turkish, folded into C in English.
        let three = [app("dev.zed.Zed", "Zed"), app("com.example.calisma", "Çalışma"), app("com.todesktop.cursor", "Cursor")]
        check(names(entries([clip], three, locale: tr).visible) == ["<pano>", "Cursor", "Çalışma", "Zed"],
              "Turkish order \(names(entries([clip], three, locale: tr).visible))")
        check(names(entries([clip], three, locale: en).visible) == ["<pano>", "Çalışma", "Cursor", "Zed"],
              "English order \(names(entries([clip], three, locale: en).visible))")
        let cased = [app("a", "iTerm"), app("b", "IntelliJ IDEA"), app("c", "Ifade")]
        check(names(entries([clip], cased, locale: en).visible) == ["<pano>", "Ifade", "IntelliJ IDEA", "iTerm"],
              "case-insensitive order \(names(entries([clip], cased, locale: en).visible))")

        failures += settingsChecks()
        return failures
    }

    /// `AppSettings` target list: normalising, conversion of old files, moves, ★, "Varsayılan yap".
    private static func settingsChecks() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append("targets: " + what) } }
        let clip = AppSettings.clipboard
        let tr = AppLanguage.tr.locale

        check(AppSettings().deliveryTargets == [clip], "fresh install: clipboard only")
        check(AppSettings.normalizedTargets([]) == [clip], "normalise empty")
        check(AppSettings.normalizedTargets(["a.b", clip, "a.b", clip]) == ["a.b", clip], "normalise duplicates")
        check(AppSettings.normalizedTargets(["a.b"]) == ["a.b", clip], "normalise adds clipboard")
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"deliveryTargets": ["a.b"]}"#.utf8))
        check(decoded?.deliveryTargets == ["a.b", clip], "decode adds clipboard")
        let old = try? JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"deliveryDefaultApp": "a.b", "deliveryFavorites": ["c.d"]}"#.utf8))
        check(old?.deliveryTargets == [clip], "old keys alone decode to the default (SettingsStore converts)")

        // Conversion of pre-0.4.3 settings: what the panel showed stays, ⌘ numbers too.
        let names = ["x.cursor": "Cursor", "n.notes": "Notlar", "t.textedit": "TextEdit", "c.claude": "Claude",
                     "o.openchamber": "OpenChamber", "t.telegram": "Telegram"]
        func migrated(_ def: String?, _ favs: [String]) -> [String] {
            AppSettings.migratedTargets(defaultApp: def, favorites: favs, locale: tr) { names[$0] }
        }
        check(migrated("x.cursor", ["t.textedit", "x.cursor", "n.notes"]) == ["x.cursor", "n.notes", "t.textedit", clip],
              "app default first, favourites A–Z, clipboard last")
        check(migrated(nil, ["t.textedit", "n.notes"]) == [clip, "n.notes", "t.textedit"], "clipboard default first")
        check(migrated("o.openchamber", ["c.claude", "o.openchamber", "t.telegram"])
              == ["o.openchamber", "c.claude", "t.telegram", clip], "this Mac's settings")
        check(migrated(nil, ["z.unknown", "n.notes"]) == [clip, "n.notes", "z.unknown"], "unknown app sorted by id")
        check(migrated("a.only", []) == ["a.only", clip], "default without favourites")

        // Moves (drag / ⌥↑↓).
        var s = AppSettings()
        s.deliveryTargets = ["a.a", clip, "b.b", "c.c"]
        check(s.moveTarget("b.b", by: -1) && s.deliveryTargets == ["a.a", "b.b", clip, "c.c"], "move up")
        check(s.moveTarget("b.b", by: -1) && s.defaultTarget == "b.b", "move to the top → default")
        check(!s.moveTarget("b.b", by: -1), "already at the top")
        check(s.moveTarget(clip, by: -2) && s.deliveryTargets == [clip, "b.b", "a.a", "c.c"], "clipboard can move")
        check(s.moveTarget("b.b", by: 5) && s.deliveryTargets == [clip, "a.a", "c.c", "b.b"], "move down past the end")
        check(!s.moveTarget("gone.app", by: 1), "unknown id")
        s.deliveryTargets = ["a.a", "x.gone", "b.b"]
        check(s.moveTarget("a.a", by: 1, among: ["a.a", "b.b"]) && s.deliveryTargets == ["x.gone", "b.b", "a.a"],
              "skips entries that aren't shown")

        // ★ and "Varsayılan yap".
        s.deliveryTargets = ["a.a", clip]
        s.toggleTarget("b.b")
        check(s.deliveryTargets == ["a.a", clip, "b.b"], "★ adds at the end")
        s.toggleTarget("a.a")
        check(s.deliveryTargets == [clip, "b.b"] && s.defaultTarget == clip, "★ off on the default: next is default")
        s.toggleTarget(clip)
        check(s.deliveryTargets == [clip, "b.b"], "clipboard can't be removed")
        s.makeDefaultTarget("b.b")
        check(s.deliveryTargets == ["b.b", clip], "Varsayılan yap")
        s.makeDefaultTarget("n.new")
        check(s.deliveryTargets == ["n.new", "b.b", clip], "Varsayılan yap on an app not in the list")
        check(s.hasTargetApp && !AppSettings().hasTargetApp, "hasTargetApp")

        // Auto-send: on by default (old files too), 30 s; one of 3 s, 30 s, 1, 3, 5 min.
        check(AppSettings().autoSendEnabled && AppSettings().autoSendSeconds == 30, "auto-send default")
        let older = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"sendKey": "enter"}"#.utf8))
        check(older?.autoSendEnabled == true && older?.autoSendSeconds == 30, "auto-send on for old files")
        let off = try? JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"autoSendEnabled": false, "autoSendSeconds": 42}"#.utf8))
        check(off?.autoSendEnabled == false && off?.autoSendSeconds == 30, "auto-send off, 42 → 30")
        let short = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoSendSeconds": 3}"#.utf8))
        check(short?.autoSendSeconds == 3, "3 s kept")
        check(AppSettings.autoSendChoices.allSatisfy { AppSettings.clampedAutoSend($0) == $0 }, "choices kept")
        check(AppSettings.clampedAutoSend(45) == 30 && AppSettings.clampedAutoSend(100) == 60
              && AppSettings.clampedAutoSend(1000) == 300 && AppSettings.clampedAutoSend(0) == 3
              && AppSettings.clampedAutoSend(.nan) == 30, "auto-send nearest choice")
        return failures
    }
}
#endif
