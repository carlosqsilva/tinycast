import AppKit
import SwiftUI

/// Launcher items as a table in one `Form` row, reusing a screenful of hosted rows as it scrolls.
struct LauncherItemsTable<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let isEnabled: Bool
    /// True when a row sits above the table in its section, so the table hangs over its divider too.
    var followsRow = true
    let visibility: VisibilityStore
    let aliases: AliasStore
    let hotKeys: HotKeyManager
    @ViewBuilder let row: (Item) -> Row

    /// The open recorder's bounds in this view's space; nil while nothing is recording.
    @State private var recorderFrame: CGRect?

    var body: some View {
        HostedRowsTable(
            items: items, isEnabled: isEnabled, followsRow: followsRow, visibility: visibility,
            aliases: aliases, hotKeys: hotKeys, row: row, recorderFrame: $recorderFrame
        )
        .overlay(alignment: .topLeading) { recorderStandIn }
    }

    /// The open recorder's anchor can't leave its hosted row, so this republishes its bounds here.
    @ViewBuilder
    private var recorderStandIn: some View {
        if let recorderFrame {
            Color.clear
                .frame(width: recorderFrame.width, height: recorderFrame.height)
                .anchorPreference(key: ShortcutRecorderAnchorKey.self, value: .bounds) { $0 }
                .position(x: recorderFrame.midX, y: recorderFrame.midY)
                .allowsHitTesting(false)
        }
    }
}

private enum HostedRowsMetrics {
    /// Leave a little of the Form's edge inset at the first and last rows.
    static let tableOverhang: CGFloat = 10
    static let dividerHeight: CGFloat = 1
    static let rowHeight: CGFloat = 45
}

private struct HostedRowsTable<Item: Identifiable, Row: View>: NSViewRepresentable {
    let items: [Item]
    let isEnabled: Bool
    let followsRow: Bool
    let visibility: VisibilityStore
    let aliases: AliasStore
    let hotKeys: HotKeyManager
    let row: (Item) -> Row
    @Binding var recorderFrame: CGRect?

    private var topOverhang: CGFloat {
        HostedRowsMetrics.tableOverhang + (followsRow ? HostedRowsMetrics.dividerHeight : 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let table = HostedRowsTableView()
        table.headerView = nil
        table.style = .plain
        table.rowHeight = HostedRowsMetrics.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.refusesFirstResponder = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let container = OverhangingTableView(
            table: table, topOverhang: topOverhang, bottomOverhang: HostedRowsMetrics.tableOverhang)
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.show(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let rows = CGFloat(items.count) * HostedRowsMetrics.rowHeight
        return CGSize(
            width: proposal.width ?? nsView.frame.width,
            height: rows - topOverhang - HostedRowsMetrics.tableOverhang)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate weak var table: NSTableView?
        fileprivate weak var container: NSView?
        private var list: HostedRowsTable?
        private var shownIDs: [Item.ID] = []
        private weak var recorderOwner: HostedRowCellView<Row>?

        fileprivate func show(_ list: HostedRowsTable) {
            self.list = list
            guard let table else { return }
            let ids = list.items.map(\.id)
            guard ids == shownIDs else {
                shownIDs = ids
                table.reloadData()
                return
            }
            // Same rows: refresh the visible cells in place, so a focused alias keeps its editor.
            let visible = table.rows(in: table.visibleRect)
            for row in visible.location..<visible.location + visible.length {
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                (cell as? HostedRowCellView<Row>)?.show(content(for: row, of: list))
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            list?.items.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let list else { return nil }
            let content = content(for: row, of: list)
            let reused = tableView.makeView(withIdentifier: HostedRowCellView<Row>.reuseID, owner: nil)
            let cell = reused as? HostedRowCellView<Row> ?? HostedRowCellView(content)
            cell.onTabOut = { [weak self, weak cell] in
                guard let self, let cell else { return false }
                return self.focusAlias(below: cell)
            }
            cell.onRecorderMoved = { [weak self, weak cell] frame in
                guard let self, let cell else { return }
                self.recorderMoved(to: frame, in: cell)
            }
            cell.show(content)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        private func focusAlias(below cell: HostedRowCellView<Row>) -> Bool {
            guard let table else { return false }
            let row = table.row(for: cell) + 1
            guard row > 0, row < table.numberOfRows else { return false }
            table.scrollRowToVisible(row)
            let next = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? HostedRowCellView<Row>
            return next?.focusAlias() ?? false
        }

        private func recorderMoved(to frame: CGRect?, in cell: HostedRowCellView<Row>) {
            guard let container else { return }
            if let frame {
                recorderOwner = cell
                publish(cell.convertFromHost(frame, to: container))
            } else if recorderOwner === cell {
                recorderOwner = nil
                publish(nil)
            }
        }

        private func publish(_ frame: CGRect?) {
            guard let list, list.recorderFrame != frame else { return }
            list.recorderFrame = frame
        }

        private func content(for row: Int, of list: HostedRowsTable) -> HostedRowCell<Row> {
            HostedRowCell(
                row: list.row(list.items[row]), showsDivider: row > 0, isEnabled: list.isEnabled,
                visibility: list.visibility, aliases: list.aliases, hotKeys: list.hotKeys)
        }
    }
}

/// Hangs the table into the `Form` row's padding: negative padding doesn't move an AppKit view.
private final class OverhangingTableView: NSView {
    private let table: NSTableView
    private let topOverhang: CGFloat
    private let bottomOverhang: CGFloat

    init(table: NSTableView, topOverhang: CGFloat, bottomOverhang: CGFloat) {
        self.table = table
        self.topOverhang = topOverhang
        self.bottomOverhang = bottomOverhang
        super.init(frame: .zero)
        addSubview(table)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        table.frame = NSRect(
            x: bounds.minX, y: bounds.minY - topOverhang,
            width: bounds.width, height: bounds.height + topOverhang + bottomOverhang)
    }
}

/// Hands every click to the hosted row; a table otherwise claims clicks that miss an `NSControl`.
private final class HostedRowsTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

/// A reused row: its hosted text field and checkbox survive, and only the item changes hands.
private final class HostedRowCellView<Row: View>: NSTableCellView {
    static var reuseID: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("hostedRow") }
    var onTabOut: () -> Bool = { false }
    var onRecorderMoved: (CGRect?) -> Void = { _ in }
    private let host: NSHostingView<HostedRowCell<Row>>

    init(_ content: HostedRowCell<Row>) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        identifier = Self.reuseID
        // The table fixes the row height; a hosting view left to size itself would fight it.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ content: HostedRowCell<Row>) {
        var content = content
        content.onRecorderFrame = { [weak self] frame in self?.onRecorderMoved(frame) }
        content.onTab = { [weak self] in self?.tabbed() ?? false }
        host.rootView = content
    }

    func convertFromHost(_ frame: CGRect, to view: NSView) -> CGRect {
        host.convert(frame, to: view)
    }

    func focusAlias() -> Bool {
        guard let field = aliasField else { return false }
        return window?.makeFirstResponder(field) ?? false
    }

    /// Only while the alias is being edited, so Tab off a focused checkbox keeps its default.
    private func tabbed() -> Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSView, field.isDescendant(of: host)
        else { return false }
        return onTabOut()
    }

    /// The row's one editable text field is its alias; the name and the recorder are drawn text.
    private var aliasField: NSTextField? {
        var pending: [NSView] = [host]
        while let view = pending.popLast() {
            if let field = view as? NSTextField, field.isEditable { return field }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
}

/// What a cell hosts: the row, plus the hairline and environment a `Form` row would hand it.
private struct HostedRowCell<Row: View>: View {
    let row: Row
    let showsDivider: Bool
    let isEnabled: Bool
    let visibility: VisibilityStore
    let aliases: AliasStore
    let hotKeys: HotKeyManager
    var onRecorderFrame: @MainActor (CGRect?) -> Void = { _ in }
    var onTab: @MainActor () -> Bool = { false }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(showsDivider ? 1 : 0)
            row
                // Rows are separate hosting views; the key view loop doesn't run from one to the next.
                .onKeyPress(.tab, phases: .down) { press in
                    !press.modifiers.contains(.shift) && onTab() ? .handled : .ignored
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .disabled(!isEnabled)
        // The recorder's anchor can't leave this hosting view; its bounds go out by hand.
        .overlayPreferenceValue(ShortcutRecorderAnchorKey.self) { anchor in
            GeometryReader { proxy in
                Color.clear.onChange(of: anchor.map { proxy[$0] }, initial: true) { _, frame in
                    onRecorderFrame(frame)
                }
            }
        }
        .environment(visibility)
        .environment(aliases)
        .environment(hotKeys)
        .motionScope()
    }
}
