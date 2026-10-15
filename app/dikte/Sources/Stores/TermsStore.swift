import Foundation
import Observation

/// terms.json — `{"terms": [Term]}`. Seeded on first run from the engine's `GET /terms/default`.
@Observable
final class TermsStore {
    private(set) var terms: [Term] = []
    @ObservationIgnored var onChange: (([Term]) -> Void)?

    @ObservationIgnored private let url: URL

    private struct File: Codable {
        var terms: [Term]
    }

    init() {
        url = Paths.termsFile
        if let file = StoreJSON.load(LenientFile.self, from: url) {
            terms = Self.normalized(file.terms.map(\.term))
        }
        // No file: stay empty so AppState seeds from the engine; written on first change.
    }

    var isEmpty: Bool { terms.isEmpty }

    func replaceAll(_ terms: [Term]) {
        commit(Self.normalized(terms))
    }

    /// Insert, or replace the term with the same canonical spelling (case-insensitive).
    func upsert(_ term: Term) {
        let t = Self.clean(term)
        guard !t.term.isEmpty else { return }
        var list = terms
        if let i = list.firstIndex(where: { $0.term.turkishFolded == t.term.turkishFolded }) {
            list[i] = t
        } else {
            list.append(t)
        }
        commit(list)
    }

    func delete(term: String) {
        let key = term.turkishFolded
        let list = terms.filter { $0.term.turkishFolded != key }
        if list.count != terms.count { commit(list) }
    }

    /// Learning: record that `wrong` should become `right`. Adds `wrong` to the `fix` list of the
    /// term whose canonical spelling equals `right` (case-insensitive), or creates a new term.
    func addFix(wrong: String, right: String) {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        let wKey = wrong.turkishFolded
        guard !wKey.isEmpty, !right.isEmpty, wKey != right.turkishFolded else { return }
        var list = terms
        if let i = list.firstIndex(where: { $0.term.turkishFolded == right.turkishFolded }) {
            if list[i].fix.contains(where: { $0.turkishFolded == wKey }) { return }
            list[i].fix.append(wrong)
            // A spelling can't be both accepted and auto-fixed.
            list[i].accept.removeAll { $0.turkishFolded == wKey }
        } else {
            list.append(Term(term: right, accept: [], fix: [wrong]))
        }
        commit(list)
    }

    // MARK: - Private

    private func commit(_ list: [Term]) {
        guard list != terms else { return }
        terms = list
        StoreJSON.save(File(terms: terms), to: url)
        onChange?(terms)
    }

    /// Trim, drop empty entries, dedupe terms and their accept/fix lists (case-insensitive).
    private static func normalized(_ list: [Term]) -> [Term] {
        var seen = Set<String>()
        var out: [Term] = []
        for raw in list {
            let t = clean(raw)
            guard !t.term.isEmpty, seen.insert(t.term.turkishFolded).inserted else { continue }
            out.append(t)
        }
        return out
    }

    private static func clean(_ t: Term) -> Term {
        func dedupe(_ xs: [String]) -> [String] {
            var seen = Set<String>()
            return xs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.turkishFolded).inserted }
        }
        return Term(term: t.term.trimmingCharacters(in: .whitespacesAndNewlines),
                    accept: dedupe(t.accept), fix: dedupe(t.fix))
    }

    /// Tolerates missing `accept` / `fix` keys in hand-edited files.
    private struct LenientFile: Decodable {
        var terms: [LenientTerm]
    }

    private struct LenientTerm: Decodable {
        var term: Term
        enum CodingKeys: String, CodingKey { case term, accept, fix }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            term = Term(term: try c.decode(String.self, forKey: .term),
                        accept: try c.decodeIfPresent([String].self, forKey: .accept) ?? [],
                        fix: try c.decodeIfPresent([String].self, forKey: .fix) ?? [])
        }
    }
}
