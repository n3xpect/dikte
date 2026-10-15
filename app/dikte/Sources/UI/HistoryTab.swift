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
                SearchField(prompt: L("Geçmişte ara"), text: $query)
                    .frame(maxWidth: 320)
                Text(query.isEmpty
                     ? Fmt.count(entries.count, one: L("1 kayıt"), other: { L("%@ kayıt", $0) })
                     : L("%@ / %@ kayıt", Fmt.int(filtered.count), Fmt.int(entries.count)))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(L("Tümünü temizle"), systemImage: "trash", role: .destructive) { confirmClear = true }
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
        .confirmationDialog(L("Tüm geçmiş silinsin mi?"), isPresented: $confirmClear) {
            Button(L("Tümünü sil"), role: .destructive) {
                clear()
                selection = nil
            }
            Button(L("Vazgeç"), role: .cancel) {}
        } message: {
            Text(Fmt.count(entries.count, one: L("1 kayıt kalıcı olarak silinir."),
                           other: { L("%@ kayıt kalıcı olarak silinir.", $0) }))
        }
    }

    @ViewBuilder private var list: some View {
        if entries.isEmpty {
            placeholder(L("Henüz dikte yok"), L("%@ ile dikte ettiklerin burada görünür.", Hotkeys.dictateDisplay), "clock")
        } else if filtered.isEmpty {
            placeholder(L("Sonuç yok"), L("“%@” için kayıt bulunamadı.", query), "magnifyingglass")
        } else {
            List(filtered, selection: $selection) { entry in
                HistoryRow(entry: entry, modelLabel: modelLabel(entry.model),
                           copy: { Clipboard.copy(entry.editedText) },
                           delete: { remove(entry.id) })
                    .tag(entry.id)
                    .contextMenu {
                        Button(L("Kopyala")) { Clipboard.copy(entry.editedText) }
                        Button(L("Ham metni kopyala")) { Clipboard.copy(entry.rawText) }
                        Divider()
                        Button(L("Sil"), role: .destructive) { remove(entry.id) }
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
            placeholder(L("Kayıt seç"), L("Ham çıktı ile son metin arasındaki farkları görmek için soldan bir kayıt seç."),
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
        Badge(text: copied ? L("kopyalandı") : L("kopyalanmadı"),
              systemImage: copied ? "doc.on.clipboard" : nil,
              color: copied ? Palette.loaded : .secondary,
              style: copied ? .tinted : .outline)
    }
}

/// Dictation language of an entry; entries from before 0.2.0 have none and were Turkish.
private struct LanguageTag: View {
    var language: String?
    var body: some View {
        let code = (language ?? "tr").uppercased()
        Badge(text: code, color: .secondary, style: .outline)
            .help(code == "EN" ? L("İngilizce dikte") : code == "TR" ? L("Türkçe dikte") : code)
    }
}

private func durations(_ e: HistoryEntry) -> String {
    L("%@ ses · %@ çeviri", Fmt.seconds(e.audioSeconds), Fmt.seconds(e.transcribeSeconds))
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
                LanguageTag(language: entry.language)
                CopiedTag(copied: entry.copied)
                Spacer()
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L("Kopyala"))
                Button(action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(L("Sil"))
            }
            Text(entry.editedText.isEmpty ? L("(boş)") : entry.editedText)
                .lineLimit(3)
                .foregroundStyle(entry.editedText.isEmpty ? .secondary : .primary)
            Text(verbatim: "\(modelLabel) · \(durations(entry))")
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Fmt.date(entry.date)).font(.headline)
                        LanguageTag(language: entry.language)
                        CopiedTag(copied: entry.copied)
                    }
                    Text(verbatim: "\(modelLabel) · \(durations(entry))").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Kopyala"), systemImage: "doc.on.doc") { Clipboard.copy(entry.editedText) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    Button(L("Sil"), systemImage: "trash", role: .destructive, action: delete)
                }

                section(L("Son metin")) {
                    Text(entry.editedText).textSelection(.enabled)
                }
                section(L("Değişiklikler")) {
                    if entry.rawText == entry.editedText {
                        Text(L("Ham çıktı değiştirilmeden kullanıldı.")).foregroundStyle(.secondary)
                    } else {
                        Text(WordDiff.attributed(WordDiff.diff(entry.rawText, entry.editedText)))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                        HStack(spacing: 12) {
                            Text(WordDiff.attributed([.removed(L("silinen"))]))
                            Text(WordDiff.attributed([.added(L("eklenen"))]))
                        }
                        .font(.caption)
                    }
                }
                section(L("Ham çıktı")) {
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
