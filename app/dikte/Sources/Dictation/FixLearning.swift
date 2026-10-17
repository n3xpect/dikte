import Foundation
#if DEBUG
import AppKit  // self-check builds an NSTextView
#endif

/// Learning step after delivery: finds words the user corrected in the text area that look like
/// term fixes (e.g. «cage» → «cache»). Pure logic, no state.
///
/// Turkish results: a replacement counts when it is spelled like a term (English/software look).
/// English results: everything looks like that, so only replacements by an existing term
/// (its spelling or an accepted spelling, case-insensitive) count.
enum FixLearning {
    static let maxSuggestions = 3
    /// Longest phrase (in words) on either side of a replacement that still counts as a fix.
    static let maxPhraseWords = 3

    struct Token: Equatable {
        /// Word with leading/trailing punctuation removed.
        var core: String
        /// `core` folded for comparison (case, dotted/dotless i, apostrophe variants).
        var key: String
    }

    static func suggestions(original: String, edited: String, terms: [Term],
                            language: String = "tr") -> [FixSuggestion] {
        var known = Set<String>()
        for t in terms {
            known.insert(fold(t.term))
            for a in t.accept { known.insert(fold(a)) }
        }
        var out: [FixSuggestion] = []
        var seen = Set<String>()
        for hunk in hunks(tokens(original), tokens(edited)) {
            guard (1...maxPhraseWords).contains(hunk.wrong.count),
                  (1...maxPhraseWords).contains(hunk.right.count),
                  let s = candidate(wrong: hunk.wrong.map(\.core), right: hunk.right.map(\.core), known: known,
                                    knownOnly: language == "en")
            else { continue }
            let id = fold(s.wrong) + "→" + fold(s.right)
            guard seen.insert(id).inserted else { continue }
            out.append(s)
            if out.count == maxSuggestions { break }
        }
        return out
    }

    // MARK: - Tokens & diff

    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?…\"'“”‘’„«»‹›()[]{}<>*`–—-")
    private static let turkishLocale = Locale(identifier: "tr_TR")

    static func fold(_ s: String) -> String {
        s.lowercased(with: turkishLocale)
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "\u{307}", with: "")
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Whitespace-separated words; pure punctuation tokens are dropped so adding/removing them is no change.
    static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let core = String(raw).trimmingCharacters(in: edgePunctuation)
            let key = fold(core)
            return key.isEmpty ? nil : Token(core: core, key: key)
        }
    }

    /// Replaced runs between the longest common subsequence of `a` and `b` (compared by `key`).
    static func hunks(_ a: [Token], _ b: [Token]) -> [(wrong: [Token], right: [Token])] {
        let n = a.count, m = b.count
        guard n * m <= 1_000_000 else { return [] }
        let w = m + 1
        var dp = [Int](repeating: 0, count: (n + 1) * w)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i * w + j] = a[i].key == b[j].key
                    ? dp[(i + 1) * w + j + 1] + 1
                    : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
            }
        }
        var out: [(wrong: [Token], right: [Token])] = []
        var wrong: [Token] = [], right: [Token] = []
        func flush() {
            if !wrong.isEmpty || !right.isEmpty { out.append((wrong, right)) }
            wrong = []; right = []
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i].key == b[j].key {
                flush(); i += 1; j += 1
            } else if j < m, i == n || dp[i * w + j + 1] >= dp[(i + 1) * w + j] {
                right.append(b[j]); j += 1
            } else {
                wrong.append(a[i]); i += 1
            }
        }
        flush()
        return out
    }

    // MARK: - Is this replacement a term fix?

    static func candidate(wrong: [String], right: [String], known: Set<String>,
                          knownOnly: Bool = false) -> FixSuggestion? {
        var w = wrong, r = right
        // Turkish suffixes after an apostrophe ("branch'i") — compare and store stems only.
        let (wStem, wSuffix) = splitApostrophe(w[w.count - 1])
        let (rStem, rSuffix) = splitApostrophe(r[r.count - 1])
        switch (wSuffix != nil, rSuffix != nil) {
        case (true, true): w[w.count - 1] = wStem; r[r.count - 1] = rStem
        case (false, true): r[r.count - 1] = rStem   // "keşe" → "cache'i"
        case (true, false): return nil
        case (false, false): break
        }
        let wrongText = w.joined(separator: " "), rightText = r.joined(separator: " ")
        let wk = fold(wrongText), rk = fold(rightText)
        guard !wk.isEmpty, !rk.isEmpty, wk != rk else { return nil }   // case / punctuation / suffix only
        guard !known.contains(wk) else { return nil }   // swapping one term for another is a content edit
        if known.contains(rk) { return FixSuggestion(wrong: wrongText, right: rightText) }
        if knownOnly { return nil }
        if w.count == 1, r.count == 1, isSuffixChange(wk, rk) { return nil }
        guard looksLikeTerm(rightText, replacing: wrongText) else { return nil }
        return FixSuggestion(wrong: wrongText, right: rightText)
    }

    static func splitApostrophe(_ word: String) -> (stem: String, suffix: String?) {
        guard let i = word.firstIndex(where: { $0 == "'" || $0 == "’" }), i != word.startIndex else {
            return (word, nil)
        }
        return (String(word[..<i]), String(word[word.index(after: i)...]))
    }

    private static let turkishLetters = Set("abcçdefgğhıijklmnoöprsştuüvyz")
    private static let turkishOnly = Set("çğıöşüÇĞİÖŞÜ")
    private static let vowels = Set("aeıioöuü")

    /// "kodu" → "kodda": same stem, only short Turkish endings differ.
    static func isSuffixChange(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        let tails = a[p...] + b[p...]
        return p >= 4 && a.count - p <= 4 && b.count - p <= 4 && tails.allSatisfy(turkishLetters.contains)
    }

    /// Heuristic: the replacement is spelled like an English/software term rather than a Turkish word.
    static func looksLikeTerm(_ right: String, replacing wrong: String) -> Bool {
        guard right.contains(where: \.isLetter), !right.contains(where: turkishOnly.contains) else { return false }
        if wrong.contains(where: turkishOnly.contains) { return true }   // "brenç" → "branch"
        for word in right.split(separator: " ").map(String.init) {
            if word.dropFirst().contains(where: \.isUppercase) { return true }   // GitHub, iOS, API
            if word.contains(where: \.isNumber), word.contains(where: \.isLetter) { return true }   // S3, ec2
            if word.contains(where: { ".-_/+#".contains($0) }) { return true }   // Node.js, C#, CI/CD
            let l = Array(word.lowercased())
            if l.contains(where: { "qwx".contains($0) }) { return true }
            let s = String(l)
            if ["ch", "sh", "th", "ph", "wh", "ck", "ee", "oo", "ea", "ou", "gh", "oa"].contains(where: s.contains) {
                return true
            }
            if l.count >= 3, l[l.count - 1] == l[l.count - 2], !vowels.contains(l[l.count - 1]) { return true }   // pull
            if l.count >= 2, !vowels.contains(l[0]), !vowels.contains(l[1]),
               l[0].isLetter, l[1].isLetter { return true }   // stack, branch, cluster
        }
        return false
    }
}

#if DEBUG
/// Assertions for the learning heuristics. `DictationSelfCheck.run()` returns failure descriptions.
enum DictationSelfCheck {
    @discardableResult
    static func run() -> [String] {
        let terms = [Term(term: "Kubernetes"), Term(term: "branch", fix: ["brenç"]), Term(term: "Redis"),
                     Term(term: "Node.js", accept: ["NodeJS"])]
        let tr: [(String, String, [String])] = [
            ("Redis cage temizle", "Redis cache temizle", ["cage→cache"]),
            ("branch'ı merge et", "branch'i merge et", []),
            ("Merhaba dünya nasılsın", "Merhaba, dünya. Nasılsın?", []),
            ("merhaba Dünya", "Merhaba dünya", []),
            ("brenç'i sil", "branch'i sil", ["brenç→branch"]),
            ("kodu çalıştır", "kodda çalıştır", []),
            ("yeni pul request aç", "yeni pull request aç", ["pul→pull"]),
            ("kubernetis'e deploy et", "Kubernetes'e deploy et", ["kubernetis→Kubernetes"]),
            ("get hub actions çalışmıyor", "GitHub actions çalışmıyor", ["get hub→GitHub"]),
            ("bunu yarın yaparız", "bunu bugün akşam hemen yapalım", []),
            ("keşe temizle", "cache'i temizle", ["keşe→cache"]),
            ("Redis'i kapat", "Postgres'i kapat", []),
            ("note js kur", "Node.js kur", ["note js→Node.js"]),
            ("ev güzel", "ev çok güzel", []),
            ("a cage b keş c kaş d dök e", "a cache b cash c crash d dock e", ["cage→cache", "keş→cash", "kaş→crash"]),
            ("", "", []),
        ]
        // English results: only replacements by a known term spelling (case-insensitive).
        let en: [(String, String, [String])] = [
            ("clear the redis cage", "clear the Redis cache", []),
            ("I want to go home", "I need to go home", []),
            ("deploy it to cooper netties", "deploy it to Kubernetes", ["cooper netties→Kubernetes"]),
            ("merge the brunch first", "merge the branch first", ["brunch→branch"]),
            ("the brunch's tests fail", "the branch's tests fail", ["brunch→branch"]),
            ("restart readies now", "restart REDIS now", ["readies→REDIS"]),
            ("install note js", "install NodeJS", ["note js→NodeJS"]),
            ("Redis is down", "Postgres is down", []),
            ("open a pull request", "open a new pull request", []),
            ("get hub actions fail", "GitHub actions fail", []),
            ("", "", []),
        ]
        var failures: [String] = []
        for (language, cases) in [("tr", tr), ("en", en)] {
            for (original, edited, expected) in cases {
                let got = FixLearning.suggestions(original: original, edited: edited, terms: terms, language: language)
                    .map { "\($0.wrong)→\($0.right)" }
                if got != expected {
                    failures.append("[\(language)] «\(original)» → «\(edited)»: beklenen \(expected), gelen \(got)")
                }
            }
        }
        failures += deliveryFailures()
        for f in failures { print("DictationSelfCheck FAIL:", f) }
        assert(failures.isEmpty, "DictationSelfCheck failed:\n" + failures.joined(separator: "\n"))
        return failures
    }

    /// Hint row, ⌘digit key mapping, toast texts and the preview list order / shortcut lookup.
    private static func deliveryFailures() -> [String] {
        var failures: [String] = []
        func expect<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            if got != want { failures.append("\(what): beklenen \(want), gelen \(got)") }
        }
        let keys = { (items: [DeliveryHint.Item]) in items.map(\.key) }
        // ↩ sends (default).
        let app = DeliveryHint.items(defaultName: "Slack", shortcuts: 9, canSwitchLanguage: false)
        expect(keys(app), ["↩", "⇧↩", "⌘1–9", "⌘C", "Esc"], "ipucu (uygulama)")
        expect(app[0].label, "Slack", "ipucu ↩ adı")
        expect(app[1].label, L("yeni satır"), "ipucu ⇧↩ yeni satır")
        let clip = DeliveryHint.items(defaultName: nil, shortcuts: 4, canSwitchLanguage: true)
        expect(keys(clip), ["↩", "⇧↩", "⌘1–4", "⌘L", "Esc"], "ipucu (pano)")
        expect(clip[0].label, L("kopyala"), "ipucu ↩ pano")
        expect(keys(DeliveryHint.items(defaultName: nil, shortcuts: 0, canSwitchLanguage: false)),
               ["↩", "⇧↩", "Esc"], "ipucu (liste boş)")
        expect(keys(DeliveryHint.items(defaultName: "Mail", shortcuts: 1, canSwitchLanguage: false)),
               ["↩", "⇧↩", "⌘1", "⌘C", "Esc"], "ipucu (tek kısayol)")
        expect(keys(DeliveryHint.items(defaultName: "Slack", shortcuts: 5, canSwitchLanguage: true, hasList: true)),
               ["↩", "⇧↩", "↓", "⌘1–5", "⌘C", "⌘L", "Esc"], "ipucu (↩, liste)")
        // ⇧↩ sends (the old order).
        let shiftApp = DeliveryHint.items(defaultName: "Slack", shortcuts: 9, canSwitchLanguage: false,
                                          sendKey: .shiftEnter)
        expect(keys(shiftApp), ["Enter", "⇧↩", "⌘1–9", "⌘C", "Esc"], "ipucu ⇧↩ (uygulama)")
        expect(shiftApp[1].label, "Slack", "ipucu ⇧↩ adı")
        expect(keys(DeliveryHint.items(defaultName: nil, shortcuts: 4, canSwitchLanguage: true, sendKey: .shiftEnter)),
               ["Enter", "⇧↩", "⌘1–4", "⌘L", "Esc"], "ipucu ⇧↩ (pano)")
        expect(keys(DeliveryHint.items(defaultName: "Slack", shortcuts: 5, canSwitchLanguage: true, hasList: true,
                                       sendKey: .shiftEnter)),
               ["Enter", "↓", "⇧↩", "⌘1–5", "⌘C", "⌘L", "Esc"], "ipucu ⇧↩ (liste)")
        expect(SendKey.enter.symbol, "↩", "gönderme tuşu ↩")
        expect(SendKey.shiftEnter.symbol, "⇧↩", "gönderme tuşu ⇧↩")

        // Settings: missing / unknown sendKey → Enter; round trip keeps the choice.
        let decode = { (json: String) in try? JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)) }
        expect(decode("{}")?.sendKey, .enter, "sendKey yok → enter")
        expect(decode(#"{"sendKey":"shiftEnter"}"#)?.sendKey, .shiftEnter, "sendKey shiftEnter")
        expect(decode(#"{"sendKey":"tab"}"#)?.sendKey, .enter, "sendKey bilinmeyen → enter")
        var shiftSettings = AppSettings()
        shiftSettings.sendKey = .shiftEnter
        expect((try? JSONEncoder().encode(shiftSettings)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }?
               .sendKey, .shiftEnter, "sendKey kaydet/oku")

        failures += keyActionFailures()
        expect(String(DeliveryHint.attributed([.init(key: "⇧↩", label: "*Slack*")]).characters), "⇧↩ *Slack*",
               "ipucu: ad markdown sayılmaz")

        expect((0...127).compactMap { DictationPanelController.shortcutNumber(keyCode: UInt16($0)) }.sorted(),
               Array(1...9), "⌘ rakam tuşları")
        expect(DictationPanelController.shortcutNumber(keyCode: 18), 1, "keyCode 18")
        expect(DictationPanelController.shortcutNumber(keyCode: 25), 9, "keyCode 25")
        expect(DictationPanelController.shortcutNumber(keyCode: 29), nil, "keyCode 29 (0)")

        expect(DeliveryToastContent.failure(DeliveryError.accessibilityDenied, appName: "Slack").asksForAccessibility,
               true, "toast: erişilebilirlik")
        let paste = DeliveryToastContent.failure(DeliveryError.pasteFailed, appName: "Slack")
        expect(paste.asksForAccessibility, false, "toast: yapıştırma")
        expect(paste.message.contains("Slack"), true, "toast: uygulama adı")
        expect(DeliveryToastContent.failure(CancellationError(), appName: "X").asksForAccessibility, false,
               "toast: başka hata")

        // Preview list (Slack default, then Mail, Notes, the clipboard; 3 others visible, 3 more).
        let c = DictationController.preview(.deliveryApp)
        let names = { (entries: [DeliveryEntry]) in entries.map { $0.app?.name ?? "pano" } }
        expect(names(c.shownDeliveryEntries), ["Slack", "Mail", "Notes", "pano", "Calendar", "Finder", "Messages"],
               "liste")
        expect(c.hiddenDeliveryCount, 3, "+N")
        expect(c.shownDeliveryEntries.map { $0.shortcut ?? 0 }, [0, 1, 2, 3, 4, 5, 6], "kısayollar")
        expect(keys(c.editingHint), ["↩", "⇧↩", "↓", "⌘1–6", "⌘C", "⌘L", "Esc"], "düzenleme ipucu")
        let shiftPanel = DictationController.preview(.deliveryShiftEnter)
        expect(shiftPanel.sendKey, .shiftEnter, "önizleme ⇧↩")
        expect(keys(shiftPanel.editingHint), ["Enter", "↓", "⇧↩", "⌘1–6", "⌘C", "⌘L", "Esc"], "düzenleme ipucu ⇧↩")
        // ↑/↓ navigation: 7 rows + "+3 more" = 8 slots.
        expect(c.navigableRowCount, 8, "↓ satır sayısı")
        expect(c.enterList(), true, "↓ listeye gir")
        expect(c.listSelection, 0, "↓ ilk satır")
        expect(keys(c.editingHint), ["↑↓", "⌥↑↓", "↩", "Esc"], "liste ipucu (taşınabilir)")
        // ⌥↑/⌥↓: the selected row moves and stays selected; at the top it becomes the default.
        c.listSelection = 2
        c.moveSelectedTarget(by: -1)
        expect(names(c.shownDeliveryEntries).prefix(4), ["Slack", "Notes", "Mail", "pano"], "⌥↑ taşı")
        expect(c.listSelection, 1, "⌥↑ seçim izler")
        c.moveSelectedTarget(by: -1)
        expect(c.shownDeliveryEntries.first?.app?.name, "Notes", "⌥↑ en üste: varsayılan")
        expect(c.shownDeliveryEntries.first?.role, .defaultTarget, "en üstteki varsayılan")
        expect(c.listSelection, 0, "⌥↑ seçim en üstte")
        c.moveSelectedTarget(by: -1)
        expect(c.listSelection, 0, "⌥↑ en üstte durur")
        c.moveSelectedTarget(by: 3)
        expect(names(c.shownDeliveryEntries).prefix(4), ["Slack", "Mail", "pano", "Notes"], "⌥↓ üç kez")
        expect(c.listSelection, 3, "⌥↓ seçim izler")
        c.moveSelectedTarget(by: 1)
        expect(c.listSelection, 3, "⌥↓ listenin sonunda durur (diğer uygulamalara geçmez)")
        c.listSelection = 4
        expect(keys(c.editingHint), ["↑↓", "↩", "Esc"], "liste ipucu (diğer uygulama)")
        c.moveSelectedTarget(by: -1)
        expect(names(c.shownDeliveryEntries)[4], "Calendar", "diğer uygulama taşınmaz")
        c.listSelection = 0
        c.moveListSelection(by: 10)
        expect(c.listSelection, 7, "↓ son satırda durur")
        c.moveListSelection(by: -1)
        expect(c.listSelection, 6, "↑")
        c.listSelection = 7
        c.activateListSelection()
        expect(c.showsAllDeliveryTargets, true, "↩ +N listeyi açar")
        expect(c.listSelection, 7, "↩ +N sonrası seçim yerinde")
        expect(c.navigableRowCount, 10, "açılmış liste satır sayısı")
        c.listSelection = 0
        c.moveListSelection(by: -1)
        expect(c.listSelection, nil, "↑ ilk satırdan metne döner")
        c.showsAllDeliveryTargets = false

        // ↓ leaves the text only from the last visual line.
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(x: 0, y: 0, width: 160, height: 200)
        tv.textContainer?.widthTracksTextView = true
        func caretLast(_ text: String, at loc: Int) -> Bool {
            tv.string = text
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            return DictationPanelController.caretOnLastLine(tv)
        }
        expect(caretLast("", at: 0), true, "boş metin")
        expect(caretLast("kısa", at: 2), true, "tek satır")
        expect(caretLast("bir\niki", at: 1), false, "iki satır, üstte")
        expect(caretLast("bir\niki", at: 6), true, "iki satır, altta")
        expect(caretLast("bir\n", at: 4), true, "sonda boş satır, imleç orada")
        expect(caretLast("bir\n", at: 1), false, "sonda boş satır, imleç üstte")
        let long = String(repeating: "uzun kelimeler ", count: 6)
        expect(caretLast(long, at: 0), false, "kaydırılmış satır, başta")
        expect(caretLast(long, at: (long as NSString).length), true, "kaydırılmış satır, sonda")
        tv.string = "seçim"
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        expect(DictationPanelController.caretOnLastLine(tv), false, "seçim varken")
        c.showsAllDeliveryTargets = true
        expect(c.shownDeliveryEntries.count, 10, "genişletilmiş liste")
        expect(c.hiddenDeliveryCount, 0, "genişletilmiş +N")
        c.toggleFavorite(TargetApp(bundleID: "com.apple.Safari", name: "Safari", url: nil, isRunning: true))
        expect(names(c.shownDeliveryEntries).prefix(5), ["Slack", "Mail", "pano", "Notes", "Safari"],
               "yıldız: listenin sonuna")
        if let mail = c.shownDeliveryEntries.first(where: { $0.app?.name == "Mail" }) { c.makeDefaultTarget(mail) }
        expect(names(c.shownDeliveryEntries).first, "Mail", "varsayılan yap")
        if let clip = c.shownDeliveryEntries.first(where: { $0.app == nil }) { c.makeDefaultTarget(clip) }
        expect(c.shownDeliveryEntries.first?.app == nil, true, "pano varsayılan yapılabilir")
        expect(DictationController.preview(.editing).shownDeliveryEntries.first?.app, nil, "pano varsayılanı")
        return failures
    }

    /// `PanelKeyAction.editing` for both send keys: send / newline / double-Enter guard / list / rest.
    private static func keyActionFailures() -> [String] {
        var failures: [String] = []
        typealias Key = DictationPanelController.Key
        let ret = Key.returnKey, enter = Key.keypadEnter
        func act(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "",
                 _ send: SendKey, _ change: (inout PanelKeyAction.Context) -> Void = { _ in }) -> PanelKeyAction {
            var c = PanelKeyAction.Context(sendKey: send, listAvailable: true, secondsSinceEditing: 5)
            change(&c)
            return PanelKeyAction.editing(keyCode: keyCode, flags: flags, characters: chars, context: c)
        }
        func expect(_ got: PanelKeyAction, _ want: PanelKeyAction, _ what: String) {
            if got != want { failures.append("tuş \(what): beklenen \(want), gelen \(got)") }
        }

        for send in SendKey.allCases {
            let m = "[\(send.rawValue)]"
            let sendFlags: NSEvent.ModifierFlags = send == .enter ? [] : .shift
            let lineFlags: NSEvent.ModifierFlags = send == .enter ? .shift : []
            expect(act(ret, sendFlags, "", send), .deliverDefault, "\(m) gönder")
            expect(act(enter, sendFlags, "", send), .deliverDefault, "\(m) keypad gönder")
            expect(act(ret, lineFlags, "", send), send == .enter ? .newline : .pass, "\(m) yeni satır")
            expect(act(ret, [.shift, .capsLock], "", send), send == .enter ? .newline : .deliverDefault,
                   "\(m) caps lock sayılmaz")
            expect(act(ret, .option, "", send), .pass, "\(m) ⌥↩ metne")
            // Double-Enter guard: only the send key, only right after the result appeared.
            expect(act(ret, sendFlags, "", send) { $0.secondsSinceEditing = 0.1 }, .ignore, "\(m) çift Enter")
            expect(act(ret, sendFlags, "", send) { $0.secondsSinceEditing = 0.31 }, .deliverDefault, "\(m) 0,3 sn sonra")
            expect(act(ret, lineFlags, "", send) { $0.secondsSinceEditing = 0.1 }, send == .enter ? .newline : .pass,
                   "\(m) çift Enter yeni satırı engellemez")
            // List mode: ↩ delivers the row, ⇧↩ does nothing, the guard doesn't apply.
            let list: (inout PanelKeyAction.Context) -> Void = { $0.listSelected = true; $0.secondsSinceEditing = 0 }
            expect(act(ret, [], "", send, list), .activateList, "\(m) liste ↩")
            expect(act(ret, .shift, "", send, list), .ignore, "\(m) liste ⇧↩")
            expect(act(Key.down, [], "", send, list), .moveList(1), "\(m) liste ↓")
            expect(act(Key.up, [], "", send, list), .moveList(-1), "\(m) liste ↑")
            expect(act(Key.escape, [], "", send, list), .leaveList, "\(m) liste Esc")
            expect(act(Key.down, .option, "", send, list), .moveTarget(1), "\(m) liste ⌥↓ taşı")
            expect(act(Key.up, .option, "", send, list), .moveTarget(-1), "\(m) liste ⌥↑ taşı")
            expect(act(Key.up, [.option, .shift], "", send, list), .leaveListAndPass, "\(m) liste ⌥⇧↑")
            expect(act(Key.down, .option, "", send) { $0.caretOnLastLine = true }, .pass, "\(m) metinde ⌥↓")
            expect(act(0, [], "a", send, list), .leaveListAndPass, "\(m) liste yazı")
            expect(act(19, .command, "2", send, list), .deliverShortcut(2), "\(m) liste ⌘2")
            // Entering the list.
            expect(act(Key.down, [], "", send) { $0.caretOnLastLine = true }, .enterList, "\(m) ↓ listeye")
            expect(act(Key.down, [], "", send), .pass, "\(m) ↓ metinde")
            expect(act(Key.down, [], "", send) { $0.caretOnLastLine = true; $0.listAvailable = false }, .pass,
                   "\(m) ↓ liste yok")
            // Unchanged keys.
            expect(act(Key.escape, [], "", send), .escape, "\(m) Esc")
            expect(act(18, .command, "1", send), .deliverShortcut(1), "\(m) ⌘1")
            expect(act(8, .command, "c", send), .copyOnly, "\(m) ⌘C")
            expect(act(8, .command, "c", send) { $0.hasTextSelection = true }, .editingCommand(swallowOthers: false),
                   "\(m) ⌘C seçimle")
            expect(act(37, .command, "l", send), .switchLanguage, "\(m) ⌘L")
            expect(act(0, [], "a", send), .pass, "\(m) yazı")
            // Language-switch confirmation: ↩ confirms.
            expect(act(ret, [], "", send) { $0.confirmingLanguageSwitch = true }, .switchLanguage, "\(m) onay ↩")
            // IME, suggestions banner, re-transcription.
            expect(act(ret, sendFlags, "", send) { $0.hasMarkedText = true }, .pass, "\(m) IME")
            expect(act(ret, sendFlags, "", send) { $0.suggestionsShown = true }, .pass, "\(m) öneriler ↩")
            expect(act(Key.escape, [], "", send) { $0.suggestionsShown = true }, .dismissSuggestions, "\(m) öneriler Esc")
            expect(act(ret, sendFlags, "", send) { $0.retranscribing = true }, .ignore, "\(m) yeniden çevirirken")
            expect(act(8, .command, "c", send) { $0.retranscribing = true }, .editingCommand(swallowOthers: true),
                   "\(m) yeniden çevirirken ⌘C")
        }
        return failures
    }
}
#endif
