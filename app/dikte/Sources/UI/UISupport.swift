import AppKit
import SwiftUI

// Shared formatting, colors and small views for the main window.

/// Formatting in the UI language (`Localizer.shared.language`). Reading the language here keeps
/// SwiftUI bodies / observation-tracked code that format values in sync with language changes.
enum Fmt {
    /// Turkish locale for text processing (search folding, term sorting) — not UI-language dependent.
    static let tr = Locale(identifier: "tr_TR")
    private static let gib = 1_073_741_824.0

    static var locale: Locale { Localizer.shared.language.locale }

    /// "3,1 GB" / "3.1 GB" (binary GB, so the "En az boş disk alanı" setting reads as a round number).
    static func gb(_ bytes: Int64) -> String {
        let v = Double(bytes) / gib
        let digits = v >= 100 || v == v.rounded() ? 0 : 1
        return v.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + Fmt.nbsp + "GB"
    }

    /// "3", "3,5" / "3.5"
    static func number(_ v: Double, maxFraction: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(0...maxFraction)).locale(locale))
    }

    /// "1.234" / "1,234"
    static func int(_ v: Int) -> String { v.formatted(.number.locale(locale)) }

    /// "%62" in Turkish, "62%" in English; rounded down so 100% means done.
    static func percent(_ fraction: Double) -> String {
        let whole = (fraction * 100).rounded(.down) / 100
        return whole.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "3,5 sn" / "3.5 s"
    static func seconds(_ s: Double) -> String {
        L("%@ sn", number(s)).replacingOccurrences(of: " ", with: nbsp)
    }

    /// Keeps a number and its unit on one line.
    static let nbsp = "\u{00A0}"

    /// "4:05"
    /// Auto-send wait: "3 sn", "30 sn", "1 dk", "5 dk".
    static func autoSendWait(_ seconds: Double) -> String {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0
            ? L("%@ dk", int(Int(seconds / 60))).replacingOccurrences(of: " ", with: nbsp)
            : self.seconds(seconds)
    }

    /// Countdown in the panel: "18", or "4:59" from a minute up.
    static func countdownLabel(_ left: TimeInterval) -> String {
        let s = Int(left.rounded(.up))
        return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)"
    }

    /// Panel counter while recording: "00:42 / 02:00" (elapsed capped at the limit).
    static func recordingClock(elapsed: TimeInterval, limit: TimeInterval) -> String {
        func mmss(_ t: TimeInterval) -> String {
            let s = max(0, Int(t))
            return String(format: "%02d:%02d", s / 60, s % 60)
        }
        return "\(mmss(min(elapsed, limit))) / \(mmss(limit))"
    }

    static func countdown(_ s: TimeInterval) -> String {
        let total = max(0, Int(s.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
    }

    /// Count + noun with the English singular handled by a separate "1 …" key:
    /// `count(n, one: L("1 kayıt"), other: { L("%@ kayıt", $0) })`.
    static func count(_ n: Int, one: @autoclosure () -> String, other: (String) -> String) -> String {
        n == 1 ? one() : other(int(n))
    }
}

/// Turkish-aware, case- and diacritic-insensitive matching ("isik" finds "Işık").
enum TurkishSearch {
    static func fold(_ s: String) -> String {
        s.lowercased(with: Fmt.tr)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Fmt.tr)
            .replacingOccurrences(of: "ı", with: "i")
    }

    /// Every whitespace-separated token of `query` must occur in one of `fields`.
    static func matches(_ query: String, _ fields: [String]) -> Bool {
        let tokens = fold(query).split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = fields.map(fold).joined(separator: "\n")
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

enum Palette {
    static let loaded = Color(nsColor: .systemGreen)
    /// Readable green for text on a light green background.
    static let loadedText = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.40, green: 0.85, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.48, blue: 0.20, alpha: 1)
    })
    static let loading = Color(nsColor: .systemOrange)
    static let downloading = Color(nsColor: .systemBlue)
    static let danger = Color(nsColor: .systemRed)
}

/// Small capsule label.
struct Badge: View {
    enum Style { case filled, tinted, outline }
    var text: String
    var systemImage: String? = nil
    var color: Color
    var style: Style = .tinted

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(style == .filled ? Color.white : color)
        .background {
            switch style {
            case .filled: Capsule().fill(color)
            case .tinted: Capsule().fill(color.opacity(0.15))
            case .outline: Capsule().strokeBorder(color, lineWidth: 1)
            }
        }
        .fixedSize()
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Search field used at the top of list panes.
struct SearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Aramayı temizle"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension EngineStatus {
    /// Status line text and dot color for the UI.
    var display: (text: String, color: Color) {
        switch self {
        case .running: (L("Motor çalışıyor"), Palette.loaded)
        case .starting: (L("Motor başlatılıyor…"), Palette.loading)
        case .stopped: (L("Motor çalışmıyor"), Palette.danger)
        case .failed(let message): (L("Motor çalışmıyor: %@", message), Palette.danger)
        }
    }
}
