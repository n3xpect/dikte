import Foundation
#if DEBUG
import AppKit  // self-check builds an NSTextView
#endif

/// Learning step after Shift+Enter: finds words the user corrected in the text area that look like
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
        let app = DeliveryHint.items(defaultName: "Slack", shortcuts: 9, canSwitchLanguage: false)
        expect(keys(app), ["Enter", "⇧↩", "⌘1–9", "⌘C", "Esc"], "ipucu (uygulama)")
        expect(app[1].label, "Slack", "ipucu ⇧↩ adı")
        let clip = DeliveryHint.items(defaultName: nil, shortcuts: 4, canSwitchLanguage: true)
        expect(keys(clip), ["Enter", "⇧↩", "⌘1–4", "⌘L", "Esc"], "ipucu (pano)")
        expect(clip[1].label, L("kopyala"), "ipucu ⇧↩ pano")
        expect(keys(DeliveryHint.items(defaultName: nil, shortcuts: 0, canSwitchLanguage: false)),
               ["Enter", "⇧↩", "Esc"], "ipucu (liste boş)")
        expect(keys(DeliveryHint.items(defaultName: "Mail", shortcuts: 1, canSwitchLanguage: false)),
               ["Enter", "⇧↩", "⌘1", "⌘C", "Esc"], "ipucu (tek kısayol)")
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

        // Preview list (Slack default, Notes + Mail favourites, 3 others visible, 3 more).
        let c = DictationController.preview(.deliveryApp)
        let names = { (entries: [DeliveryEntry]) in entries.map { $0.app?.name ?? "pano" } }
        expect(names(c.shownDeliveryEntries), ["Slack", "Mail", "Notes", "Calendar", "Finder", "Messages"], "liste")
        expect(c.hiddenDeliveryCount, 3, "+N")
        expect(c.shownDeliveryEntries.map { $0.shortcut ?? 0 }, [0, 1, 2, 3, 4, 5], "kısayollar")
        expect(keys(c.editingHint), ["Enter", "↓", "⇧↩", "⌘1–5", "⌘C", "⌘L", "Esc"], "düzenleme ipucu")
        // ↑/↓ navigation: 6 rows + "+3 more" = 7 slots.
        expect(c.navigableRowCount, 7, "↓ satır sayısı")
        expect(c.enterList(), true, "↓ listeye gir")
        expect(c.listSelection, 0, "↓ ilk satır")
        expect(keys(c.editingHint), ["↑↓", "↩", "Esc"], "liste ipucu")
        c.moveListSelection(by: 10)
        expect(c.listSelection, 6, "↓ son satırda durur")
        c.moveListSelection(by: -1)
        expect(c.listSelection, 5, "↑")
        c.listSelection = 6
        c.activateListSelection()
        expect(c.showsAllDeliveryTargets, true, "↩ +N listeyi açar")
        expect(c.listSelection, 6, "↩ +N sonrası seçim yerinde")
        expect(c.navigableRowCount, 9, "açılmış liste satır sayısı")
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
        expect(c.shownDeliveryEntries.count, 9, "genişletilmiş liste")
        expect(c.hiddenDeliveryCount, 0, "genişletilmiş +N")
        c.toggleFavorite(TargetApp(bundleID: "com.apple.Safari", name: "Safari", url: nil, isRunning: true))
        expect(names(c.shownDeliveryEntries).prefix(4), ["Slack", "Mail", "Notes", "Safari"], "yıldız: yeniden sırala")
        c.makeDefaultTarget(TargetApp(bundleID: "com.apple.mail", name: "Mail", url: nil, isRunning: true))
        expect(names(c.shownDeliveryEntries).first, "Mail", "varsayılan yap")
        c.dismissDeliveryTip()
        expect(c.showsDeliveryTip, false, "ipucunu kapat")
        expect(DictationController.preview(.editing).shownDeliveryEntries.first?.app, nil, "pano varsayılanı")
        return failures
    }
}
#endif
