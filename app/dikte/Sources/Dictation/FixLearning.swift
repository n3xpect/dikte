import Foundation

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
        for f in failures { print("DictationSelfCheck FAIL:", f) }
        assert(failures.isEmpty, "DictationSelfCheck failed:\n" + failures.joined(separator: "\n"))
        return failures
    }
}
#endif
