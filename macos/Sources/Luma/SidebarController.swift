import AppKit

struct Destination: Equatable {
    var title: String
    var symbol: String
    var key: String
    var parentID: String? = nil
}

final class SidebarController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    static let primary = [
        Destination(title: L10n.ui("navigation.watchNow"), symbol: "play.rectangle", key: "home"),
        Destination(title: L10n.ui("navigation.movies"), symbol: "film", key: "movie"),
        Destination(title: L10n.ui("navigation.shows"), symbol: "tv", key: "series"),
        Destination(title: L10n.ui("navigation.favorites"), symbol: "heart", key: "favorites")
    ]
    private let table = NSTableView()
    private let serverTitle = UI.label(L10n.ui("sidebar.disconnected"), size: 12, weight: .semibold)
    private let serverSubtitle = UI.label(L10n.ui("sidebar.preview"), size: 11, color: .secondaryLabelColor)
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
        table.setAccessibilityLabel(L10n.ui("sidebar.accessibility"))
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
        let group = UI.label(L10n.ui("sidebar.library"), size: 11, weight: .semibold, color: .secondaryLabelColor)
        let serverIcon = NSImageView(image: NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil)!)
        serverIcon.contentTintColor = .secondaryLabelColor
        let serverLabels = UI.stack([serverTitle, serverSubtitle], spacing: 3)
        serverSubtitle.maximumNumberOfLines = 2
        serverSubtitle.lineBreakMode = .byWordWrapping
        serverSubtitle.widthAnchor.constraint(lessThanOrEqualTo: serverLabels.widthAnchor).isActive = true
        let serverRow = UI.stack([serverIcon, serverLabels], vertical: false, spacing: 10)
        serverButton.title = L10n.ui("menu.connect")
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
        serverTitle.stringValue = session?.serverName ?? L10n.ui("sidebar.disconnected")
        serverSubtitle.stringValue = session.map { L10n.ui("sidebar.account", $0.userName) } ?? L10n.ui("sidebar.preview")
        serverButton.title = session == nil ? L10n.ui("menu.connect") : L10n.ui("sidebar.manage")
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
