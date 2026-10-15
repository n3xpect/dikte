import AppKit
import SwiftUI

/// Geçmiş wired to the live store.
struct HistoryTab: View {
    let state: AppState

    var body: some View {
        let labels = Dictionary(state.engine.models.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        HistoryView(
            entries: state.history.entries,
            modelLabel: { labels[$0] ?? $0 },
            delete: state.history.delete(ids:),
            clear: state.history.clear
        )
    }
}

struct HistoryView: View {
    var entries: [HistoryEntry]
    var modelLabel: (String) -> String
    var delete: (Set<UUID>) -> Void
    var clear: () -> Void

    @State private var query = ""
    @State private var selection: UUID?
    @State private var confirmClear = false

    init(entries: [HistoryEntry], modelLabel: @escaping (String) -> String,
         delete: @escaping (Set<UUID>) -> Void, clear: @escaping () -> Void,
         selection: UUID? = nil) {
        self.entries = entries
        self.modelLabel = modelLabel
        self.delete = delete
        self.clear = clear
        _selection = State(initialValue: selection)
    }

    private var filtered: [HistoryEntry] {
        entries
            .filter { TurkishSearch.matches(query, [$0.editedText, $0.rawText, modelLabel($0.model)]) }
            .sorted { $0.date > $1.date }
    }

    private var selected: HistoryEntry? { entries.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchField(prompt: "Geçmişte ara", text: $query)
                    .frame(maxWidth: 320)
                Text(query.isEmpty ? "\(entries.count) kayıt" : "\(filtered.count) / \(entries.count) kayıt")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Tümünü temizle", systemImage: "trash", role: .destructive) { confirmClear = true }
                    .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 340)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("Tüm geçmiş silinsin mi?", isPresented: $confirmClear) {
            Button("Tümünü sil", role: .destructive) {
                clear()
                selection = nil
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("\(entries.count) kayıt kalıcı olarak silinir.")
        }
    }

    @ViewBuilder private var list: some View {
        if entries.isEmpty {
            placeholder("Henüz dikte yok", "⌥Space ile dikte ettiklerin burada görünür.", "clock")
        } else if filtered.isEmpty {
            placeholder("Sonuç yok", "“\(query)” için kayıt bulunamadı.", "magnifyingglass")
        } else {
            List(filtered, selection: $selection) { entry in
                HistoryRow(entry: entry, modelLabel: modelLabel(entry.model),
                           copy: { Clipboard.copy(entry.editedText) },
                           delete: { remove(entry.id) })
                    .tag(entry.id)
                    .contextMenu {
                        Button("Kopyala") { Clipboard.copy(entry.editedText) }
                        Button("Ham metni kopyala") { Clipboard.copy(entry.rawText) }
                        Divider()
                        Button("Sil", role: .destructive) { remove(entry.id) }
                    }
            }
            .listStyle(.inset)
            .onDeleteCommand { if let selection { remove(selection) } }
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = selected {
            HistoryDetail(entry: entry, modelLabel: modelLabel(entry.model), delete: { remove(entry.id) })
        } else {
            placeholder("Kayıt seç", "Ham çıktı ile son metin arasındaki farkları görmek için soldan bir kayıt seç.",
                        "text.magnifyingglass")
        }
    }

    private func placeholder(_ title: String, _ text: String, _ symbol: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remove(_ id: UUID) {
        if selection == id { selection = nil }
        delete([id])
    }
}

private struct CopiedTag: View {
    var copied: Bool
    var body: some View {
        Badge(text: copied ? "kopyalandı" : "kopyalanmadı",
              systemImage: copied ? "doc.on.clipboard" : nil,
              color: copied ? Palette.loaded : .secondary,
              style: copied ? .tinted : .outline)
    }
}

private func durations(_ e: HistoryEntry) -> String {
    "\(Fmt.seconds(e.audioSeconds)) ses · \(Fmt.seconds(e.transcribeSeconds)) çeviri"
}

private struct HistoryRow: View {
    var entry: HistoryEntry
    var modelLabel: String
    var copy: () -> Void
    var delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Fmt.date(entry.date)).font(.caption.weight(.semibold))
                CopiedTag(copied: entry.copied)
                Spacer()
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Kopyala")
                Button(action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Sil")
            }
            Text(entry.editedText.isEmpty ? "(boş)" : entry.editedText)
                .lineLimit(3)
                .foregroundStyle(entry.editedText.isEmpty ? .secondary : .primary)
            Text("\(modelLabel) · \(durations(entry))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryDetail: View {
    var entry: HistoryEntry
    var modelLabel: String
    var delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Fmt.date(entry.date)).font(.headline)
                        Text("\(modelLabel) · \(durations(entry))").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    CopiedTag(copied: entry.copied)
                }
                HStack {
                    Button("Kopyala", systemImage: "doc.on.doc") { Clipboard.copy(entry.editedText) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button("Sil", systemImage: "trash", role: .destructive, action: delete)
                }

                section("Son metin") {
                    Text(entry.editedText).textSelection(.enabled)
                }
                section("Değişiklikler") {
                    if entry.rawText == entry.editedText {
                        Text("Ham çıktı değiştirilmeden kullanıldı.").foregroundStyle(.secondary)
                    } else {
                        Text(WordDiff.attributed(WordDiff.diff(entry.rawText, entry.editedText)))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                        HStack(spacing: 12) {
                            Text(WordDiff.attributed([.removed("silinen")]))
                            Text(WordDiff.attributed([.added("eklenen")]))
                        }
                        .font(.caption)
                    }
                }
                section("Ham çıktı") {
                    Text(entry.rawText).textSelection(.enabled).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}
