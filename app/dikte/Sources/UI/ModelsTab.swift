import AppKit
import SwiftUI

struct ModelActions {
    var select: (String) -> Void
    var download: (String) async throws -> Void
    var cancelDownload: (String) async throws -> Void
    var delete: (String) async throws -> Void
    var load: (String) async throws -> Void
    var unload: () async throws -> Void
    var addCustom: (String) async throws -> ModelInfo
    var removeCustom: (String) async throws -> Void
    var restartEngine: () -> Void
}

/// Modeller wired to the live engine.
struct ModelsTab: View {
    let state: AppState

    var body: some View {
        let engine = state.engine
        let settings = state.settings
        ModelsView(
            status: engine.status,
            models: engine.models,
            system: engine.system,
            selectedModel: settings.settings.selectedModel,
            minFreeDiskGB: settings.settings.minFreeDiskGB,
            actions: ModelActions(
                select: { settings.settings.selectedModel = $0 },
                download: engine.download,
                cancelDownload: engine.cancelDownload,
                delete: engine.delete,
                load: engine.load,
                unload: engine.unload,
                addCustom: { try await engine.addCustom(repo: $0) },
                removeCustom: engine.removeCustom,
                restartEngine: { engine.stop(); engine.start() }
            )
        )
    }
}

struct ModelsView: View {
    var status: EngineStatus
    var models: [ModelInfo]
    var system: SystemInfo?
    var selectedModel: String
    var minFreeDiskGB: Int
    var actions: ModelActions

    @State private var errors: [String: String] = [:]
    @State private var busy: Set<String> = []
    @State private var pendingDelete: ModelInfo?
    @State private var pendingRemove: ModelInfo?
    @State private var customRepo = ""
    @State private var customMessage: (text: String, isError: Bool)?

    private static let engineKey = "_engine"
    private static let customKey = "_custom"

    private var running: Bool { if case .running = status { true } else { false } }
    private var minFree: Int64 { system?.minFreeBytes ?? Int64(minFreeDiskGB) * 1_073_741_824 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                engineCard
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Modeller")).font(.title3.weight(.semibold))
                    Text(L("Dikte, seçili modeli (◉) kullanır. Bellekte aynı anda tek model bulunur."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                if models.isEmpty {
                    Text(running ? L("Model listesi bekleniyor…") : L("Model listesi için motorun çalışması gerekiyor."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
                ForEach(models) { model in
                    ModelRow(
                        model: model,
                        isSelected: model.id == selectedModel,
                        disk: diskCheck(for: model),
                        reclaimable: reclaimable(excluding: model.id),
                        error: errors[model.id],
                        busy: busy.contains(model.id),
                        enabled: running,
                        select: { actions.select(model.id) },
                        download: { run(model.id) { try await actions.download(model.id) } },
                        cancel: { run(model.id) { try await actions.cancelDownload(model.id) } },
                        load: { run(model.id) { try await actions.load(model.id) } },
                        unload: { run(model.id) { try await actions.unload() } },
                        delete: { pendingDelete = $0 },
                        remove: { pendingRemove = model }
                    )
                }
                customCard
            }
            .padding(20)
        }
        .confirmationDialog(
            L("“%@” silinsin mi?", pendingDelete?.label ?? ""),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { m in
            Button(L("Sil"), role: .destructive) { run(m.id) { try await actions.delete(m.id) } }
            Button(L("Vazgeç"), role: .cancel) {}
        } message: { m in
            Text(L("Model dosyaları (%@) diskten silinir. Gerekirse yeniden indirebilirsin.", Fmt.gb(m.downloadedBytes)))
        }
        .confirmationDialog(
            L("“%@” listeden kaldırılsın mı?", pendingRemove?.label ?? ""),
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            presenting: pendingRemove
        ) { m in
            Button(L("Kaldır"), role: .destructive) { run(m.id) { try await actions.removeCustom(m.id) } }
            Button(L("Vazgeç"), role: .cancel) {}
        } message: { _ in
            Text(L("İndirilmiş dosyaları da silinir."))
        }
    }

    // MARK: Engine card

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(status.display.color).frame(width: 10, height: 10)
                Text(status.display.text).font(.headline)
                    .lineLimit(2)
                Spacer()
                Button(L("Yeniden başlat"), systemImage: "arrow.clockwise", action: actions.restartEngine)
                    .disabled(status == .starting)
            }
            if running {
                Divider()
                memoryLine
                if let system {
                    HStack(spacing: 18) {
                        Label {
                            Text(L("%@ boş · en az %@ boş kalmalı", Fmt.gb(system.diskFreeBytes), Fmt.gb(system.minFreeBytes)))
                        } icon: { Image(systemName: "internaldrive") }
                        Label {
                            Text(L("RAM: %@ kullanılabilir / %@", Fmt.gb(system.ramAvailableBytes), Fmt.gb(system.ramTotalBytes)))
                        } icon: { Image(systemName: "memorychip") }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            if let e = errors[Self.engineKey] {
                Text(e).font(.callout).foregroundStyle(Palette.danger)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private var memoryLine: some View {
        let loaded = models.first { $0.state == .loaded }
        let loading = models.first { $0.state == .loading }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "memorychip.fill")
                .foregroundStyle(loaded != nil ? Palette.loaded : loading != nil ? Palette.loading : .secondary)
            if let loaded {
                Text(L("Bellekte:"))
                Text(loaded.label).fontWeight(.semibold).foregroundStyle(Palette.loadedText)
                if let ram = loaded.ramBytes { Text(verbatim: "· ~\(Fmt.gb(ram)) RAM").foregroundStyle(.secondary) }
                idleCountdown.foregroundStyle(.secondary)
            } else if let loading {
                Text(L("Belleğe yükleniyor:"))
                Text(loading.label).fontWeight(.semibold).foregroundStyle(Palette.loading)
            } else {
                Text(L("Bellekte model yok")).foregroundStyle(.secondary)
                Text(L("· ilk diktede seçili model yüklenir")).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(L("Şimdi boşalt"), systemImage: "eject") {
                run(Self.engineKey) { try await actions.unload() }
            }
            .disabled(loaded == nil || busy.contains(Self.engineKey))
        }
    }

    @ViewBuilder private var idleCountdown: some View {
        if let at = system?.idleUnloadAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(L("· %@ sonra boşaltılacak", Fmt.countdown(at - ctx.date.timeIntervalSince1970)))
                    .monospacedDigit()
            }
        } else if system?.idleUnloadS == 0 {
            Text(L("· otomatik boşaltma kapalı"))
        }
    }

    // MARK: Custom models

    private var customCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Hugging Face'ten model ekle")).font(.headline)
            Text(L("MLX Whisper modeli içeren bir deponun adını veya bağlantısını yaz."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(L("Depo"), text: $customRepo, prompt: Text(L("ör. %@", "mlx-community/whisper-large-v3-turbo")))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCustom)
                    .labelsHidden()
                Button(L("Ekle"), systemImage: "plus", action: addCustom)
                    .disabled(Self.normalizedRepo(customRepo) == nil || !running || busy.contains(Self.customKey))
                if busy.contains(Self.customKey) { ProgressView().controlSize(.small) }
            }
            if let customMessage {
                Label(customMessage.text,
                      systemImage: customMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(customMessage.isError ? Palette.danger : Palette.loadedText)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.top, 8)
    }

    /// "org/name" from a repo id or a huggingface.co URL.
    static func normalizedRepo(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "huggingface.co/", "hf.co/"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !parts[0].contains(" "), !parts[1].contains(" ") else { return nil }
        return parts[0] + "/" + parts[1]
    }

    private func addCustom() {
        guard let repo = Self.normalizedRepo(customRepo), running else { return }
        customMessage = nil
        busy.insert(Self.customKey)
        Task {
            defer { busy.remove(Self.customKey) }
            do {
                let info = try await actions.addCustom(repo)
                customMessage = (L("“%@” eklendi. Kullanmak için indir.", info.label), false)
                customRepo = ""
            } catch {
                customMessage = (Self.message(error), true)
            }
        }
    }

    // MARK: Disk guard

    private func diskCheck(for model: ModelInfo) -> DiskCheck? {
        guard model.state == .notDownloaded || model.state == .paused else { return nil }
        guard let system else { return .unknownFree }
        guard let size = model.sizeBytes else { return .unknownSize(free: system.diskFreeBytes) }
        let needed = max(0, size - model.downloadedBytes)
        return .known(needed: needed, free: system.diskFreeBytes, minFree: minFree)
    }

    /// Other models with files on disk, offered for deletion when space is short.
    private func reclaimable(excluding id: String) -> [ModelInfo] {
        models.filter { $0.id != id && $0.downloadedBytes > 0 && $0.state != .downloading }
    }

    // MARK: Actions

    private func run(_ key: String, _ op: @escaping () async throws -> Void) {
        errors[key] = nil
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do { try await op() } catch { errors[key] = Self.message(error) }
        }
    }

    static func message(_ error: Error) -> String {
        if let e = error as? EngineAPIError, !e.message.isEmpty { return e.message }
        return error.localizedDescription
    }
}

enum DiskCheck: Equatable {
    case unknownFree
    case unknownSize(free: Int64)
    case known(needed: Int64, free: Int64, minFree: Int64)

    var allowsDownload: Bool {
        if case .known(let needed, let free, let minFree) = self { return free - needed >= minFree }
        return true
    }
}

private struct ModelRow: View {
    var model: ModelInfo
    var isSelected: Bool
    var disk: DiskCheck?
    var reclaimable: [ModelInfo]
    var error: String?
    var busy: Bool
    var enabled: Bool
    var select: () -> Void
    var download: () -> Void
    var cancel: () -> Void
    var load: () -> Void
    var unload: () -> Void
    var delete: (ModelInfo) -> Void
    var remove: () -> Void

    private var isLoaded: Bool { model.state == .loaded }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: select) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? (isLoaded ? Palette.loaded : Color.accentColor) : .secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? L("Dikte bu modeli kullanıyor") : L("Dikte için bu modeli seç"))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.label)
                        .font(.headline)
                        .foregroundStyle(isLoaded ? Palette.loadedText : .primary)
                    if model.recommended { Badge(text: L("Önerilen"), systemImage: "star.fill", color: .accentColor) }
                    if model.custom { Badge(text: L("Özel"), color: .purple) }
                    Spacer(minLength: 8)
                    StateBadge(model: model)
                }
                if !model.note.isEmpty {
                    Text(model.note).font(.callout).foregroundStyle(.secondary)
                }
                Text(detailLine).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)

                if model.state == .downloading { downloadProgress }
                if model.state == .paused, let e = model.error {
                    Label(e, systemImage: "pause.circle").font(.callout).foregroundStyle(Palette.loading)
                }
                if let disk { DiskGuardView(check: disk, reclaimable: reclaimable, enabled: enabled, delete: delete) }
                if isSelected { selectionHint }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Palette.danger)
                }
                HStack(spacing: 8) {
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    buttons
                }
                .disabled(!enabled || busy)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border, lineWidth: isLoaded ? 2 : 1))
    }

    private var detailLine: String {
        var parts = [model.repo]
        if let size = model.sizeBytes { parts.append(Fmt.gb(size)) }
        if let ram = model.ramBytes { parts.append("~\(Fmt.gb(ram)) RAM") }
        return parts.joined(separator: " · ")
    }

    private var background: Color {
        switch model.state {
        case .loaded: Palette.loaded.opacity(0.12)
        case .loading: Palette.loading.opacity(0.06)
        default: Color(nsColor: .controlBackgroundColor)
        }
    }

    private var border: Color {
        switch model.state {
        case .loaded: Palette.loaded
        case .loading: Palette.loading.opacity(0.6)
        default: isSelected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor)
        }
    }

    private var downloadProgress: some View {
        let p = model.progress ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: p).tint(Palette.downloading)
            if let size = model.sizeBytes {
                Text(verbatim: "\(Fmt.gb(model.downloadedBytes)) / \(Fmt.gb(size))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder private var selectionHint: some View {
        switch model.state {
        case .notDownloaded, .paused:
            Label(L("Seçili model henüz indirilmedi; dikte için önce indirmen gerekiyor."), systemImage: "info.circle")
                .font(.callout).foregroundStyle(Palette.loading)
        case .downloading:
            Label(L("İndirme bitince dikte bu modeli kullanır."), systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .onDisk:
            Label(L("İlk diktede belleğe yüklenir."), systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .loading, .loaded:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.state {
        case .notDownloaded:
            Button(L("İndir"), systemImage: "arrow.down.circle", action: download)
                .buttonStyle(.borderedProminent)
                .disabled(!(disk?.allowsDownload ?? true))
        case .downloading:
            Button(L("Durdur"), systemImage: "pause.fill", action: cancel)
        case .paused:
            Button(L("Sil"), systemImage: "trash") { delete(model) }
            Button(L("Devam et"), systemImage: "arrow.down.circle", action: download)
                .buttonStyle(.borderedProminent)
                .disabled(!(disk?.allowsDownload ?? true))
        case .onDisk:
            Button(L("Sil"), systemImage: "trash") { delete(model) }
            Button(L("Yükle"), systemImage: "memorychip", action: load)
        case .loading:
            EmptyView()
        case .loaded:
            Button(L("Sil"), systemImage: "trash") {}
                .disabled(true)
                .help(L("Bellekteki model silinemez; önce boşalt."))
            Button(L("Boşalt"), systemImage: "eject", action: unload)
        }
        if model.custom {
            Button(L("Listeden kaldır"), systemImage: "xmark", action: remove)
                .disabled([.loaded, .loading, .downloading].contains(model.state))
        }
    }
}

private struct StateBadge: View {
    var model: ModelInfo

    var body: some View {
        switch model.state {
        case .loaded:
            Badge(text: L("Bellekte"), systemImage: "checkmark.circle.fill", color: Palette.loaded, style: .filled)
        case .loading:
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Badge(text: L("Yükleniyor…"), systemImage: "hourglass", color: Palette.loading, style: .filled)
                    .opacity(0.7 + 0.3 * cos(phase * 2 * .pi))
            }
        case .onDisk:
            Badge(text: L("Diskte"), systemImage: "internaldrive", color: .secondary)
        case .downloading:
            Badge(text: L("İndiriliyor %@", Fmt.percent(model.progress ?? 0)), systemImage: "arrow.down.circle",
                  color: Palette.downloading)
        case .paused:
            Badge(text: L("Duraklatıldı"), systemImage: "pause.circle", color: Palette.downloading, style: .outline)
        case .notDownloaded:
            Badge(text: L("İndirilmedi"), color: .secondary, style: .outline)
        }
    }
}

private struct DiskGuardView: View {
    var check: DiskCheck
    var reclaimable: [ModelInfo]
    var enabled: Bool
    var delete: (ModelInfo) -> Void

    var body: some View {
        switch check {
        case .unknownFree:
            Text(L("Boş alan bilgisi yok.")).font(.callout).foregroundStyle(.secondary)
        case .unknownSize(let free):
            Text(L("Boyut henüz bilinmiyor · %@ boş", Fmt.gb(free))).font(.callout).foregroundStyle(.secondary)
        case .known(let needed, let free, let minFree):
            let after = free - needed
            VStack(alignment: .leading, spacing: 6) {
                Text(after >= 0
                     ? L("%@ inecek · %@ boş · indirme sonrası %@ kalır", Fmt.gb(needed), Fmt.gb(free), Fmt.gb(after))
                     : L("%@ inecek · %@ boş · %@ sığmıyor", Fmt.gb(needed), Fmt.gb(free), Fmt.gb(-after)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if after < minFree {
                    Label(L("Yetersiz alan: en az %@ daha yer açmalısın (en az %@ boş kalmalı).",
                            Fmt.gb(minFree - after), Fmt.gb(minFree)),
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Palette.danger)
                    if !reclaimable.isEmpty { reclaimList }
                }
            }
        }
    }

    private var reclaimList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Yer açmak için indirilmiş bir modeli silebilirsin:"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(reclaimable) { m in
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    Text(m.label)
                    Text(Fmt.gb(m.downloadedBytes)).foregroundStyle(.secondary).monospacedDigit()
                    if m.state == .loaded {
                        Text(L("bellekte · önce boşalt")).font(.caption).foregroundStyle(Palette.loadedText)
                    }
                    Spacer()
                    Button(L("Sil"), systemImage: "trash") { delete(m) }
                        .controlSize(.small)
                        .disabled(!enabled || m.state == .loaded || m.state == .loading)
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.danger.opacity(0.06)))
    }
}
