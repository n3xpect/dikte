import AppKit
import SwiftUI

/// AKTAR list under the text area: default target, favourites, other running apps, "+ N more".
struct DeliveryListView: View {
    static let rowHeight: CGFloat = 28
    /// Space for the drag handle, kept on every row so the names line up.
    static let handleWidth: CGFloat = 12
    private static let moreRowID = "+more"
    /// More rows than this scroll instead of growing the panel.
    static let maxRows = 12

    let controller: DictationController

    var body: some View {
        let rows = controller.shownDeliveryEntries
        let hidden = controller.hiddenDeliveryCount
        VStack(alignment: .leading, spacing: 4) {
            Text(L("AKTAR"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
                .padding(.leading, 6)
            rowList(rows, hidden: hidden)
        }
        .disabled(controller.retranscribing)
    }

    @ViewBuilder private func rowList(_ rows: [DeliveryEntry], hidden: Int) -> some View {
        let stack = VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, entry in
                // A line between the user's list and the other running apps.
                let firstOther = entry.role == .other && i > 0 && rows[i - 1].isMovable
                DeliveryRow(entry: entry, controller: controller, selected: controller.listSelection == i)
                    .overlay(alignment: .top) {
                        if firstOther { Divider().padding(.leading, 6 + DeliveryListView.handleWidth + 6) }
                    }
                    // By target, not position: a row that moves while dragged keeps its identity
                    // (and the drag gesture).
                    .id(entry.id)
            }
            if hidden > 0 {
                MoreRow(count: hidden, selected: controller.listSelection == rows.count) {
                    controller.showsAllDeliveryTargets = true
                }
                .id(Self.moreRowID)
            }
        }
        let count = rows.count + (hidden > 0 ? 1 : 0)
        if count > Self.maxRows {
            ScrollViewReader { proxy in
                ScrollView(.vertical) { stack }
                    .scrollIndicators(.automatic)
                    .frame(height: CGFloat(Self.maxRows) * Self.rowHeight)
                    .onChange(of: controller.listSelection) { _, i in
                        if let i { proxy.scrollTo(i < rows.count ? rows[i].id : Self.moreRowID) }
                    }
            }
        } else {
            stack
        }
    }
}

private struct DeliveryRow: View {
    let entry: DeliveryEntry
    let controller: DictationController
    /// Keyboard selection (↑/↓): accent ring + stronger fill, distinct from the default's tint.
    var selected = false
    @State private var hovering = false
    /// Handle drag: the row follows the pointer and swaps places every half row.
    @State private var dragging = false
    @State private var dragOffset: CGFloat = 0
    @State private var consumed: CGFloat = 0

    private var isDefault: Bool { entry.role == .defaultTarget }

    var body: some View {
        HStack(spacing: 6) {
            handle
            Button { controller.deliver(entry) } label: {
                HStack(spacing: 8) {
                    ShortcutChip(text: chipText)
                    icon
                    Text(name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if entry.app?.isRunning == true {
                        Circle()
                            .fill(.secondary.opacity(0.7))
                            .frame(width: 5, height: 5)
                            .help(L("Açık"))
                            .accessibilityLabel(L("Açık"))
                    }
                    if isDefault {
                        Text(L("Varsayılan"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable(false)
            if let app = entry.app {
                Button { controller.toggleFavorite(app) } label: {
                    Image(systemName: entry.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(entry.isFavorite ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(entry.isFavorite ? L("Favorilerden çıkar") : L("Favorilere ekle"))
                .accessibilityLabel(entry.isFavorite ? L("Favorilerden çıkar") : L("Favorilere ekle"))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: DeliveryListView.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .shadow(color: .black.opacity(dragging ? 0.25 : 0), radius: 6, y: 2)
        .offset(y: dragOffset)
        .zIndex(dragging ? 1 : 0)
        .onHover { hovering = $0 }
        .contextMenu {
            if !isDefault {
                Button(L("Varsayılan yap")) { controller.makeDefaultTarget(entry) }
            }
            if let app = entry.app {
                Button(entry.isFavorite ? L("Favorilerden çıkar") : L("Favorilere ekle")) {
                    controller.toggleFavorite(app)
                }
            }
        }
    }

    /// ≡ on rows of the user's list, shown on hover / selection; dragging it reorders.
    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: DeliveryListView.handleWidth, height: DeliveryListView.rowHeight)
            .contentShape(.rect)
            .opacity(entry.isMovable && (hovering || dragging || selected) ? 1 : 0)
            .allowsHitTesting(entry.isMovable)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        dragging = true
                        let h = DeliveryListView.rowHeight
                        var dy = value.translation.height - consumed
                        while dy > h / 2, controller.moveTarget(entry, by: 1) { consumed += h; dy -= h }
                        while dy < -h / 2, controller.moveTarget(entry, by: -1) { consumed -= h; dy += h }
                        dragOffset = dy
                    }
                    .onEnded { _ in
                        dragging = false
                        dragOffset = 0
                        consumed = 0
                    }
            )
            .help(L("Sıralamak için sürükle"))
            .accessibilityHidden(true)
    }

    private var chipText: String? {
        if isDefault { return controller.sendKey.symbol }
        return entry.shortcut.map { "⌘\($0)" }
    }

    private var name: String {
        entry.app?.name ?? L("Panoya kopyala")
    }

    @ViewBuilder private var icon: some View {
        if let app = entry.app {
            Image(nsImage: controller.deliveryIcon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.22) }
        if dragging { return Color(nsColor: .windowBackgroundColor) }
        if isDefault { return Color.blue.opacity(hovering ? 0.2 : 0.12) }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }
}

private struct MoreRow: View {
    let count: Int
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Color.clear.frame(width: DeliveryListView.handleWidth - 2)
                ShortcutChip(text: nil)
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(count == 1 ? L("+ 1 uygulama daha…") : L("+ %lld uygulama daha…", count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DeliveryListView.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : hovering ? Color.primary.opacity(0.07) : .clear)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

/// Fixed-width key label so names line up; empty when the row has no shortcut.
private struct ShortcutChip: View {
    let text: String?

    var body: some View {
        Text(verbatim: text ?? "")
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 18)
            .background {
                if text != nil {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.primary.opacity(0.07))
                }
            }
    }
}

// MARK: - Hint row

/// Key hints under the AKTAR list, send key first:
/// "↩ Slack · ⇧↩ yeni satır · ↓ liste · ⌘1–5 diğerleri · ⌘C kopyala · ⌘L dil · Esc kapat"
/// (⇧↩ sends: "Enter yeni satır · ↓ liste · ⇧↩ Slack · …").
enum DeliveryHint {
    struct Item: Equatable {
        var key: String
        var label: String
    }

    /// `defaultName` nil = the default target is the clipboard (then ⌘C would only repeat the send key).
    /// `shortcuts` = highest ⌘ number shown in the list.
    /// `hasList`: there are rows to reach with ↓ from the text area.
    static func items(defaultName: String?, shortcuts: Int, canSwitchLanguage: Bool,
                      hasList: Bool = false, sendKey: SendKey = .enter) -> [Item] {
        let send = Item(key: sendKey.symbol, label: defaultName ?? L("kopyala"))
        var items: [Item]
        switch sendKey {
        case .enter:
            items = [send, Item(key: sendKey.newlineSymbol, label: L("yeni satır"))]
            if hasList { items.append(Item(key: "↓", label: L("liste"))) }
        case .shiftEnter:
            items = [Item(key: "Enter", label: L("yeni satır"))]
            if hasList { items.append(Item(key: "↓", label: L("liste"))) }
            items.append(send)
        }
        if shortcuts == 1 {
            items.append(Item(key: "⌘1", label: L("diğerleri")))
        } else if shortcuts > 1 {
            items.append(Item(key: "⌘1–\(min(shortcuts, 9))", label: L("diğerleri")))
        }
        if defaultName != nil { items.append(Item(key: "⌘C", label: L("kopyala"))) }
        if canSwitchLanguage { items.append(Item(key: "⌘L", label: L("dil"))) }
        items.append(Item(key: "Esc", label: L("kapat")))
        return items
    }

    /// While a row is selected with the arrow keys; `canMove`: it is in the user's list.
    static func listItems(canMove: Bool = false) -> [Item] {
        var items = [Item(key: "↑↓", label: L("seç"))]
        if canMove { items.append(Item(key: "⌥↑↓", label: L("taşı"))) }
        return items + [Item(key: "↩", label: L("aktar")), Item(key: "Esc", label: L("metne dön"))]
    }

    /// Keys bold; labels (app names included) are plain text, never parsed as markdown.
    static func attributed(_ items: [Item]) -> AttributedString {
        var result = AttributedString()
        for (i, item) in items.enumerated() {
            if i > 0 { result += AttributedString(" · ") }
            var key = AttributedString(item.key)
            key.inlinePresentationIntent = .stronglyEmphasized
            result += key
            result += AttributedString(" " + item.label)
        }
        return result
    }
}
