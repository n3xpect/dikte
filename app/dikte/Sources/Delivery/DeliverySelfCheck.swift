#if DEBUG
import Foundation

/// Pure-logic checks for `DeliveryService.entries(...)`; run with the UI self-check
/// (`dikte --render-ui-previews <dir>`). Returns the failures.
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

        func entries(_ def: String?, _ favs: [String], _ apps: [TargetApp] = running, locale: Locale = tr,
                     limit: Int = 5) -> (visible: [DeliveryEntry], more: [DeliveryEntry]) {
            DeliveryService.entries(defaultApp: def, favorites: favs, running: apps, locale: locale, limit: limit,
                                    resolve: resolve)
        }
        func names(_ e: [DeliveryEntry]) -> [String] { e.map { $0.app?.name ?? "<pano>" } }

        // Clipboard default, no favourites: 5 others visible (Turkish A–Z), rest in more.
        var r = entries(nil, [])
        check(names(r.visible) == ["<pano>", "Cursor", "Çalışma", "Mail", "Safari", "Slack"],
              "clipboard default visible \(names(r.visible))")
        check(names(r.more) == ["Terminal", "Xcode", "Zed"], "clipboard default more \(names(r.more))")
        check(r.visible[0].role == .defaultTarget && r.visible[0].app == nil && !r.visible[0].isFavorite
              && r.visible[0].shortcut == nil && r.visible[0].id == "clipboard", "clipboard row")
        check(r.visible.dropFirst().map(\.shortcut) == [1, 2, 3, 4, 5], "⌘ numbering \(r.visible.map(\.shortcut))")
        check(r.more.allSatisfy { $0.shortcut == nil && $0.role == .other }, "more rows have no shortcut")

        // App default that is also a favourite appears once (as default); closed favourite listed.
        r = entries("com.todesktop.cursor", ["com.apple.TextEdit", "com.todesktop.cursor", "com.apple.Notes"])
        check(names(r.visible) == ["Cursor", "Notlar", "TextEdit", "Çalışma", "Mail", "Safari", "Slack", "Terminal"],
              "app default + favourites \(names(r.visible))")
        check(r.visible[0].role == .defaultTarget && r.visible[0].isFavorite, "default is favourite")
        check(r.visible.filter { $0.app?.bundleID == "com.todesktop.cursor" }.count == 1, "default only once")
        check(r.visible[1].role == .favorite && r.visible[1].isFavorite && r.visible[1].app?.isRunning == false,
              "closed favourite")
        check(r.visible.dropFirst().map(\.shortcut) == Array(1...7).map(Optional.some), "⌘ numbering with favourites")
        check(names(r.more) == ["Xcode", "Zed"], "more after favourites \(names(r.more))")

        // Uninstalled default → clipboard; uninstalled favourite skipped.
        r = entries("com.gone.app", ["com.gone.too", "com.apple.TextEdit"])
        check(r.visible[0].app == nil && r.visible[0].role == .defaultTarget, "uninstalled default → clipboard")
        check(names(r.visible).prefix(2) == ["<pano>", "TextEdit"], "uninstalled favourite skipped \(names(r.visible))")

        // Running app default (not a favourite) isn't repeated among the others.
        r = entries("dev.zed.Zed", [])
        check(r.visible[0].app?.name == "Zed" && !r.visible[0].isFavorite, "running default")
        check(!(r.visible.dropFirst() + r.more).contains { $0.app?.bundleID == "dev.zed.Zed" }, "default not in others")

        // Limits.
        r = entries(nil, [], limit: 0)
        check(r.visible.count == 1 && r.more.count == 8, "limit 0 → all in more (\(r.visible.count), \(r.more.count))")
        r = entries(nil, [], limit: 9)
        check(r.visible.count == 9 && r.more.isEmpty, "limit 9 → all visible")
        r = entries(nil, [], limit: -3)
        check(r.visible.count == 1, "negative limit")

        // ⌘ numbering stops at 9.
        let many = (0..<12).map { app("com.example.app\($0)", String(format: "App %02d", $0)) }
        r = DeliveryService.entries(defaultApp: nil, favorites: many.map(\.bundleID), running: [], locale: tr,
                                    limit: 5, resolve: { id in many.first { $0.bundleID == id } })
        check(r.visible.count == 13, "12 favourites all visible")
        check(r.visible[9].shortcut == 9 && r.visible[10].shortcut == nil, "no shortcut beyond ⌘9")

        // Locale ordering: Ç after C in Turkish, folded into C in English.
        let three = [app("dev.zed.Zed", "Zed"), app("com.example.calisma", "Çalışma"), app("com.todesktop.cursor", "Cursor")]
        check(names(entries(nil, [], three, locale: tr).visible) == ["<pano>", "Cursor", "Çalışma", "Zed"],
              "Turkish order \(names(entries(nil, [], three, locale: tr).visible))")
        check(names(entries(nil, [], three, locale: en).visible) == ["<pano>", "Çalışma", "Cursor", "Zed"],
              "English order \(names(entries(nil, [], three, locale: en).visible))")
        let cased = [app("a", "iTerm"), app("b", "IntelliJ IDEA"), app("c", "Ifade")]
        check(names(entries(nil, [], cased, locale: en).visible) == ["<pano>", "Ifade", "IntelliJ IDEA", "iTerm"],
              "case-insensitive order \(names(entries(nil, [], cased, locale: en).visible))")
        return failures
    }
}
#endif
