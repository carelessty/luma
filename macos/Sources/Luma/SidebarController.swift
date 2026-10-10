import AppKit

struct Destination: Equatable {
    var title: String
    var symbol: String
    var key: String
    var parentID: String? = nil
}

final class SidebarController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    static let primary = [
        Destination(title: "现在观看", symbol: "play.rectangle", key: "home"),
        Destination(title: "电影", symbol: "film", key: "movie"),
        Destination(title: "剧集", symbol: "tv", key: "series"),
        Destination(title: "收藏", symbol: "heart", key: "favorites")
    ]
    private let table = NSTableView()
    private let serverTitle = UI.label("尚未连接", size: 12, weight: .semibold)
    private let serverSubtitle = UI.label("正在预览 Luma", size: 11, color: .secondaryLabelColor)
    private let serverButton = NSButton()
    private var destinations = SidebarController.primary
    private var updating = false
    var onSelect: ((Destination) -> Void)?
    var onConnect: (() -> Void)?
    override func loadView() {
        view = NSView()
        table.style = .sourceList
        table.backgroundColor = .clear
        table.headerView = nil
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.focusRingType = .none
        let column = NSTableColumn(identifier: .init("destination"))
        table.addTableColumn(column)
        table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel("资料库侧边栏")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        let logo = UI.label("Luma", size: 25, weight: .bold)
        let symbol = NSImageView(image: NSImage(systemSymbolName: "play.square.stack.fill", accessibilityDescription: nil)!)
        symbol.contentTintColor = .controlAccentColor
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.widthAnchor.constraint(equalToConstant: 27).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 27).isActive = true
        let brand = UI.stack([symbol, logo], vertical: false, spacing: 10)
        let group = UI.label("资料库", size: 11, weight: .semibold, color: .secondaryLabelColor)
        let serverIcon = NSImageView(image: NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil)!)
        serverIcon.contentTintColor = .secondaryLabelColor
        let serverLabels = UI.stack([serverTitle, serverSubtitle], spacing: 3)
        let serverRow = UI.stack([serverIcon, serverLabels], vertical: false, spacing: 10)
        serverButton.title = "连接服务器…"
        serverButton.bezelStyle = .rounded
        serverButton.target = self; serverButton.action = #selector(connect)
        let separator = NSBox(); separator.boxType = .separator
        let footer = UI.stack([separator, serverRow, serverButton], spacing: 12)
        [brand, group, scroll, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), brand.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            group.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), group.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 30),
            scroll.topAnchor.constraint(equalTo: group.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18), footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            separator.widthAnchor.constraint(equalTo: footer.widthAnchor), serverButton.widthAnchor.constraint(equalTo: footer.widthAnchor), serverLabels.widthAnchor.constraint(lessThanOrEqualTo: footer.widthAnchor, constant: -32)
        ])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
    func update(session: Session?, views: [MediaItem]) {
        updating = true
        defer { updating = false }
        let selected = table.selectedRow >= 0 && table.selectedRow < destinations.count ? destinations[table.selectedRow].key : "home"
        destinations = Self.primary + views.map { Destination(title: $0.title, symbol: "rectangle.stack", key: "library-\($0.id)", parentID: $0.id) }
        serverTitle.stringValue = session?.serverName ?? "尚未连接"
        serverSubtitle.stringValue = session.map { "以 \($0.userName) 的身份连接" } ?? "正在预览 Luma"
        serverButton.title = session == nil ? "连接服务器…" : "管理连接…"
        table.reloadData()
        if let index = destinations.firstIndex(where: { $0.key == selected }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }
    func select(_ index: Int) { guard destinations.indices.contains(index) else { return }; table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    func numberOfRows(in tableView: NSTableView) -> Int { destinations.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = destinations[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        let label = UI.label(item.title, size: 13, weight: row == 0 ? .medium : .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon); cell.addSubview(label); cell.textField = label; cell.imageView = icon
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 19), icon.heightAnchor.constraint(equalToConstant: 19), label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { guard !updating, destinations.indices.contains(table.selectedRow) else { return }; onSelect?(destinations[table.selectedRow]) }
    @objc private func connect() { onConnect?() }
}
