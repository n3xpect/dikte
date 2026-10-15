import SwiftUI

/// Word-level diff between the model's raw output and the final text (LCS over words).
enum WordDiff {
    enum Op: Equatable { case same(String), removed(String), added(String) }

    static func diff(_ old: String, _ new: String) -> [Op] {
        let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
        let n = a.count, m = b.count
        // lcs[i][j] = LCS length of a[i...] and b[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var ops: [Op] = []
        var removed: [Op] = [], added: [Op] = []
        func flush() { ops += removed + added; removed = []; added = [] }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flush()
                ops.append(.same(a[i])); i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                added.append(.added(b[j])); j += 1
            } else {
                removed.append(.removed(a[i])); i += 1
            }
        }
        flush()
        return ops
    }

    static func attributed(_ ops: [Op]) -> AttributedString {
        var out = AttributedString()
        for (k, op) in ops.enumerated() {
            if k > 0 { out += AttributedString(" ") }
            switch op {
            case .same(let w):
                out += AttributedString(w)
            case .removed(let w):
                var s = AttributedString(w)
                s.foregroundColor = Palette.danger
                s.strikethroughStyle = .single
                s.backgroundColor = Palette.danger.opacity(0.12)
                out += s
            case .added(let w):
                var s = AttributedString(w)
                s.foregroundColor = Palette.loadedText
                s.backgroundColor = Palette.loaded.opacity(0.15)
                out += s
            }
        }
        return out
    }
}
