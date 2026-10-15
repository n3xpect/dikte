import SwiftUI

struct TermActions {
    var upsert: (Term) -> Void
    var delete: (String) -> Void
}

/// Term list (Terimler tab): searchable, with add / edit / delete.
struct TermsSection: View {
    var terms: [Term]
    var actions: TermActions

    @State private var query = ""
    @State private var editing: TermDraft?
    @State private var pendingDelete: Term?

    private var filtered: [Term] {
        terms
            .filter { TurkishSearch.matches(query, [$0.term] + $0.accept + $0.fix) }
            .sorted { $0.term.compare($1.term, options: .caseInsensitive, locale: Fmt.tr) == .orderedAscending }
    }

    var body: some View {
        Section {
            HStack {
                SearchField(prompt: L("Terimlerde ara"), text: $query)
                Button {
                    editing = TermDraft(original: nil, term: query.trimmingCharacters(in: .whitespaces))
                } label: {
                    Label(L("Terim ekle"), systemImage: "plus")
                }
            }
            // Presentations hang off this single row: modifiers on a Section can be applied per row.
            .sheet(item: $editing) { draft in
                TermEditor(draft: draft, existing: Set(terms.map(\.term))) { saved in
                    if let original = draft.original, original != saved.term { actions.delete(original) }
                    actions.upsert(saved)
                }
            }
            .confirmationDialog(
                L("“%@” terimi silinsin mi?", pendingDelete?.term ?? ""),
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { term in
                Button(L("Sil"), role: .destructive) { actions.delete(term.term) }
                Button(L("Vazgeç"), role: .cancel) {}
            }
            if filtered.isEmpty {
                Text(terms.isEmpty ? L("Henüz terim yok.") : L("Aramaya uyan terim yok."))
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { term in
                TermRow(term: term,
                        edit: { editing = TermDraft(term) },
                        delete: { pendingDelete = term })
            }
        } header: {
            HStack {
                Text(L("Terimler"))
                Spacer()
                Text(Fmt.count(terms.count, one: L("1 terim"), other: { L("%@ terim", $0) }))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            HStack(spacing: 12) {
                Badge(text: L("düzeltilir"), color: Palette.loading)
                Text(L("Model böyle yazarsa terime çevrilir."))
                Badge(text: L("kabul"), color: .secondary)
                Text(L("Doğru sayılan yazım."))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct TermRow: View {
    var term: Term
    var edit: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(term.term)
                .fontWeight(.semibold)
                .frame(minWidth: 110, alignment: .leading)
            FlowLayout {
                ForEach(term.fix, id: \.self) { Badge(text: $0, color: Palette.loading) }
                ForEach(term.accept, id: \.self) { Badge(text: $0, color: .secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: edit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help(L("Düzenle"))
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(L("Sil"))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }
}

struct TermDraft: Identifiable {
    let id = UUID()
    /// Term being edited (nil = new).
    var original: String?
    var term: String
    var accept: String = ""
    var fix: String = ""

    init(original: String?, term: String) {
        self.original = original
        self.term = term
    }

    init(_ t: Term) {
        original = t.term
        term = t.term
        accept = t.accept.joined(separator: ", ")
        fix = t.fix.joined(separator: ", ")
    }

    static func list(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var result: Term {
        Term(term: term.trimmingCharacters(in: .whitespacesAndNewlines),
             accept: Self.list(accept), fix: Self.list(fix))
    }
}

struct TermEditor: View {
    @State var draft: TermDraft
    var existing: Set<String>
    var save: (Term) -> Void
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { draft.term.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var overwrites: Bool { trimmed != draft.original && existing.contains(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.original == nil ? L("Yeni terim") : L("Terimi düzenle"))
                .font(.headline)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField(L("Terim"), text: $draft.term, prompt: Text(L("ör. %@", "branch")))
                    if overwrites {
                        Text(L("Bu terim zaten var; kaydedersen üzerine yazılır."))
                            .font(.callout).foregroundStyle(Palette.loading)
                    }
                } footer: {
                    Text(L("Metinde olması gereken doğru yazım.")).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField(L("Düzeltilecek yazımlar"), text: $draft.fix, prompt: Text(L("ör. %@", "brenç, branş")))
                } footer: {
                    Text(L("Virgülle ayır. Model bunlardan birini yazarsa terimle değiştirilir."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextField(L("Kabul edilen yazımlar"), text: $draft.accept, prompt: Text(L("ör. %@", "branch, Branch")))
                } footer: {
                    Text(L("Virgülle ayır. Bunlar doğru sayılır, değiştirilmez."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("Vazgeç"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Kaydet")) {
                    save(draft.result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }
}
