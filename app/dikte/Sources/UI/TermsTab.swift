import SwiftUI

/// Terimler tab wired to the live store.
struct TermsTab: View {
    let state: AppState

    var body: some View {
        TermsView(terms: state.terms.terms,
                  actions: TermActions(upsert: state.terms.upsert, delete: state.terms.delete(term:)))
    }
}

struct TermsView: View {
    var terms: [Term]
    var actions: TermActions

    var body: some View {
        Form {
            Section {
                Text(L("Terimler modele ipucu olarak verilir; böylece Türkçe cümle içindeki İngilizce kelimeler doğru yazılır. Model bir terimi yanlış yazarsa düzeltme listesindeki yazım otomatik olarak terime çevrilir."))
                    .foregroundStyle(.secondary)
            }
            TermsSection(terms: terms, actions: actions)
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
#Preview("Terimler") {
    TermsView(terms: PreviewData.terms, actions: PreviewData.termActions)
        .frame(width: 720, height: 640)
}
#endif
