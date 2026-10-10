import AppKit

@MainActor
final class ConnectController: NSWindowController {
    private let service: MediaService
    private let currentSession: Session?
    private let address = NSTextField()
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let errorLabel = UI.label(size: 12, color: .systemRed)
    private let spinner = NSProgressIndicator()
    private let submit = NSButton()
    private let disconnect = NSButton()
    private var task: Task<Void, Never>?
    var onComplete: (() -> Void)?
    var onWillChangeSession: (() async -> Void)?
    init(service: MediaService, session: Session?) {
        self.service = service; currentSession = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 570), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L10n.ui("connect.windowTitle")
        super.init(window: window)
        let root = NSView(); window.contentView = root
        let icon = NSImageView(image: NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true; icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let title = UI.label(session == nil ? L10n.ui("connect.title") : L10n.ui("connect.manageTitle"), size: 24, weight: .bold)
        let hint = UI.label(session.map { L10n.ui("connect.current", $0.serverName) } ?? L10n.ui("connect.hint"), size: 13, color: .secondaryLabelColor)
        for label in [title, hint] {
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.widthAnchor.constraint(equalToConstant: 480).isActive = true
        }
        address.placeholderString = "https://emby.example.com"
        address.stringValue = session?.serverURL ?? UserDefaults.standard.string(forKey: "luma.native.lastServer") ?? ""
        username.placeholderString = L10n.ui("connect.username")
        username.stringValue = session?.userName ?? UserDefaults.standard.string(forKey: "luma.native.lastUsername") ?? ""
        password.placeholderString = L10n.ui("connect.password")
        for (field, label) in [(address, L10n.ui("connect.address")), (username, L10n.ui("connect.username")), (password, L10n.ui("connect.password"))] {
            field.controlSize = .large
            field.font = .systemFont(ofSize: 13)
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 480).isActive = true
        }
        let form = UI.stack([UI.label(L10n.ui("connect.address"), size: 12, weight: .medium), address, UI.label(L10n.ui("connect.username"), size: 12, weight: .medium), username, UI.label(L10n.ui("connect.password"), size: 12, weight: .medium), password], spacing: 7)
        form.setCustomSpacing(14, after: address); form.setCustomSpacing(14, after: username)
        errorLabel.maximumNumberOfLines = 3; errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.widthAnchor.constraint(equalToConstant: 480).isActive = true
        let security = UI.label(L10n.ui("connect.security"), size: 11, color: .secondaryLabelColor)
        security.maximumNumberOfLines = 3
        security.lineBreakMode = .byWordWrapping
        security.widthAnchor.constraint(equalToConstant: 480).isActive = true
        let stack = UI.stack([icon, title, hint, form, security, errorLabel], spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40)])
        submit.title = session == nil ? L10n.ui("connect.submit") : L10n.ui("connect.switch"); submit.bezelStyle = .rounded; submit.keyEquivalent = "\r"; submit.target = self; submit.action = #selector(connect)
        let cancel = UI.button(L10n.ui("action.cancel"), target: self, action: #selector(closeSheet)); cancel.keyEquivalent = "\u{1b}"
        disconnect.title = L10n.ui("connect.disconnect"); disconnect.bezelStyle = .rounded; disconnect.target = self; disconnect.action = #selector(disconnectPressed); disconnect.isHidden = session == nil
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let buttons = UI.stack([spinner, cancel, submit], vertical: false, spacing: 10)
        buttons.translatesAutoresizingMaskIntoConstraints = false; disconnect.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons); root.addSubview(disconnect)
        NSLayoutConstraint.activate([buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), disconnect.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), disconnect.centerYAnchor.constraint(equalTo: buttons.centerYAnchor), disconnect.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12), stack.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -16)])
        window.initialFirstResponder = address
        address.nextKeyView = username; username.nextKeyView = password; password.nextKeyView = submit
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func connect() {
        // Commit the active field editor before reading or disabling the fields.
        guard window?.makeFirstResponder(nil) != false else { return }
        let server = address.stringValue; let name = username.stringValue; let secret = password.stringValue
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorLabel.stringValue = L10n.ui("connect.missingFields"); return }
        setBusy(true); errorLabel.stringValue = ""
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await self.onWillChangeSession?()
                try Task.checkCancellation()
                _ = try await self.service.connect(serverURL: server, username: name, password: secret)
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(server, forKey: "luma.native.lastServer")
                UserDefaults.standard.set(name, forKey: "luma.native.lastUsername")
                self.password.stringValue = ""
                self.finish(); self.onComplete?()
            } catch { guard !Task.isCancelled else { return }; self.errorLabel.stringValue = error.localizedDescription; self.setBusy(false) }
        }
    }
    @objc private func disconnectPressed() {
        setBusy(true)
        task = Task { [weak self] in
            guard let self else { return }
            do { await self.onWillChangeSession?(); try Task.checkCancellation(); try await self.service.disconnect(); self.finish(); self.onComplete?() }
            catch { self.errorLabel.stringValue = error.localizedDescription; self.setBusy(false) }
        }
    }
    private func setBusy(_ busy: Bool) { submit.isEnabled = !busy; disconnect.isEnabled = !busy; address.isEnabled = !busy; username.isEnabled = !busy; password.isEnabled = !busy; busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }
    @objc private func closeSheet() { task?.cancel(); password.stringValue = ""; finish() }
    private func finish() { if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) } }
}

@MainActor
final class DetailController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var item: MediaItem
    private let service: MediaService
    private let poster = ArtworkView()
    private let titleLabel = UI.label(size: 26, weight: .bold)
    private let metadata = UI.label(size: 12, color: .secondaryLabelColor)
    private let overviewScroll = NSTextView.scrollableTextView()
    private var overview: NSTextView { overviewScroll.documentView as! NSTextView }
    private let favorite = NSButton()
    private let play = NSButton()
    private let table = EpisodeTableView()
    private let status = UI.label(size: 12, color: .secondaryLabelColor)
    private var episodes: [MediaItem] = []
    private var task: Task<Void, Never>?
    var onPlay: ((MediaItem) -> Void)?
    var onChanged: ((MediaItem) -> Void)?
    init(item: MediaItem, service: MediaService) {
        self.item = item; self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: item.kind == .series ? 660 : 470), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L10n.ui("action.details")
        super.init(window: window)
        let root = NSView(); window.contentView = root
        poster.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(poster)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        metadata.maximumNumberOfLines = 2; metadata.lineBreakMode = .byWordWrapping
        overview.isEditable = false
        overview.isSelectable = true
        overview.drawsBackground = false
        overview.font = .systemFont(ofSize: 13)
        overview.textColor = .labelColor
        overview.textContainerInset = .zero
        overview.textContainer?.lineFragmentPadding = 0
        overview.setAccessibilityLabel(L10n.ui("detail.overview"))
        overviewScroll.drawsBackground = false
        overviewScroll.borderType = .noBorder
        overviewScroll.autohidesScrollers = true
        overviewScroll.setAccessibilityLabel(L10n.ui("detail.fullOverview"))
        play.title = item.kind == .series ? L10n.ui("detail.loadingEpisodes") : (item.positionTicks > 0 ? L10n.ui("action.resume") : L10n.ui("action.play"))
        play.isEnabled = item.kind != .series
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.imagePosition = .imageLeading; play.bezelStyle = .rounded; play.bezelColor = .controlAccentColor; play.controlSize = .large; play.target = self; play.action = #selector(playPressed)
        favorite.bezelStyle = .rounded; favorite.controlSize = .large; favorite.imagePosition = .imageLeading; favorite.target = self; favorite.action = #selector(favoritePressed)
        // The item request carries the authoritative favorite state. Allowing
        // a mutation before it arrives can overwrite the successful result.
        favorite.isEnabled = false
        let buttons = UI.stack([play, favorite], vertical: false)
        let texts = UI.stack([titleLabel, metadata, buttons, overviewScroll], spacing: 16)
        texts.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(texts)
        let overviewHeight = overviewScroll.heightAnchor.constraint(equalToConstant: item.kind == .series ? 120 : 170)
        overviewHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([poster.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), poster.topAnchor.constraint(equalTo: root.topAnchor, constant: 28), poster.widthAnchor.constraint(equalToConstant: 195), poster.heightAnchor.constraint(equalToConstant: 290), texts.leadingAnchor.constraint(equalTo: poster.trailingAnchor, constant: 26), texts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28), texts.topAnchor.constraint(equalTo: poster.topAnchor), titleLabel.widthAnchor.constraint(equalTo: texts.widthAnchor), metadata.widthAnchor.constraint(equalTo: texts.widthAnchor), overviewScroll.widthAnchor.constraint(equalTo: texts.widthAnchor), overviewHeight, overviewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70)])
        if item.kind == .series { texts.bottomAnchor.constraint(lessThanOrEqualTo: poster.bottomAnchor).isActive = true }
        else { texts.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -70).isActive = true }
        if item.kind == .series {
            let heading = UI.label(L10n.ui("detail.episodesHeading"), size: 18, weight: .semibold)
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            table.addTableColumn(NSTableColumn(identifier: .init("episodes")))
            table.headerView = nil; table.rowHeight = 45; table.style = .inset; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(episodePressed)
            table.setAccessibilityLabel(L10n.ui("detail.episodesAccessibility"))
            table.onPlaySelection = { [weak self] in self?.playSelectedEpisode() }
            scroll.documentView = table
            [heading, scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
            NSLayoutConstraint.activate([heading.leadingAnchor.constraint(equalTo: poster.leadingAnchor), heading.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 25), scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: poster.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: texts.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -75)])
        }
        let close = UI.button(L10n.ui("action.done"), target: self, action: #selector(closeSheet)); close.keyEquivalent = "\u{1b}"
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        close.translatesAutoresizingMaskIntoConstraints = false; status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(close); root.addSubview(status)
        NSLayoutConstraint.activate([close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), status.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -16), status.centerYAnchor.constraint(equalTo: close.centerYAnchor)])
        update()
        status.stringValue = L10n.ui("detail.loading")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let fullItem = try await self.service.item(id: item.id)
                guard !Task.isCancelled else { return }
                self.item = fullItem; self.update()
                self.favorite.isEnabled = true
                if fullItem.kind == .series {
                    self.episodes = try await self.service.episodes(id: item.id)
                    guard !Task.isCancelled else { return }
                    self.table.reloadData(); self.play.isEnabled = !self.episodes.isEmpty
                    self.play.title = Self.playTitle(for: fullItem, episodes: self.episodes)
                    self.status.stringValue = L10n.ui("detail.episodeCount", self.episodes.count)
                } else {
                    self.play.title = Self.playTitle(for: fullItem, episodes: [])
                    self.status.stringValue = item.id.hasPrefix("demo-") ? L10n.ui("detail.previewNotice") : ""
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.status.stringValue = error.localizedDescription
                if self.item.kind == .series { self.play.title = L10n.ui("detail.noEpisodes") }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func update() {
        titleLabel.stringValue = item.title
        let originalTitle = item.originalTitle == item.title ? "" : (item.originalTitle ?? "")
        metadata.stringValue = [originalTitle, item.metadataText].filter { !$0.isEmpty }.joined(separator: "\n")
        let description = item.overview.isEmpty ? L10n.ui("detail.noOverview") : item.overview
        if overview.string != description { overview.string = description }
        poster.setImage(item.imageURL, pixels: 600)
        favorite.title = item.isFavorite ? L10n.ui("favorite.added") : L10n.ui("favorite.action")
        favorite.image = NSImage(systemSymbolName: item.isFavorite ? "heart.fill" : "heart", accessibilityDescription: nil)
    }
    @objc private func favoritePressed() {
        guard favorite.isEnabled else { return }
        favorite.isEnabled = false
        let newValue = !item.isFavorite
        Task { [weak self] in
            guard let self else { return }
            do { try await self.service.favorite(id: self.item.id, value: newValue); self.item.isFavorite = newValue; self.update(); self.onChanged?(self.item) }
            catch { self.status.stringValue = error.localizedDescription }
            self.favorite.isEnabled = true
        }
    }
    static func playbackTarget(for item: MediaItem, episodes: [MediaItem]) -> MediaItem? {
        guard item.kind == .series else { return item }
        return episodes.first(where: { !$0.isPlayed && $0.positionTicks > 0 })
            ?? episodes.first(where: { !$0.isPlayed }) ?? episodes.first
    }
    static func playTitle(for item: MediaItem, episodes: [MediaItem]) -> String {
        guard let target = playbackTarget(for: item, episodes: episodes) else { return L10n.ui("detail.noEpisodes") }
        let action = target.positionTicks > 0 && !target.isPlayed ? L10n.ui("action.resume") : L10n.ui("action.play")
        guard item.kind == .series else { return action }
        guard let number = target.episodeNumber else { return action }
        return L10n.ui("detail.episodePlayback", action, target.seasonNumber ?? 1, number)
    }
    @objc private func playPressed() {
        let target = Self.playbackTarget(for: item, episodes: episodes)
        guard let target else { return }; closeSheet(); onPlay?(target)
    }
    @objc private func episodePressed() { playSelectedEpisode() }
    private func playSelectedEpisode() { let row = table.selectedRow; guard episodes.indices.contains(row) else { return }; let episode = episodes[row]; closeSheet(); onPlay?(episode) }
    @objc private func closeSheet() { task?.cancel(); if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) } }
    func numberOfRows(in tableView: NSTableView) -> Int { episodes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let episode = episodes[row]
        let number = L10n.ui("detail.episodeNumber", episode.seasonNumber ?? 1, episode.episodeNumber ?? row + 1)
        let label = UI.label(L10n.ui("detail.episodeTitle", number, episode.title), size: 13, weight: .medium)
        let duration = UI.label(episode.isPlayed ? L10n.ui("detail.watched") : episode.durationLabel, size: 11, color: .secondaryLabelColor)
        let stack = UI.stack([label, duration], spacing: 4)
        return stack
    }
}

final class EpisodeTableView: NSTableView {
    var onPlaySelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 49), selectedRow >= 0 { onPlaySelection?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
final class SettingsController: NSWindowController {
    private let bitrate = NSPopUpButton()
    private let autoplay = NSButton(checkboxWithTitle: L10n.ui("settings.autoplay"), target: nil, action: nil)
    private let subtitles = NSButton(checkboxWithTitle: L10n.ui("settings.subtitles"), target: nil, action: nil)
    private let appearance = NSPopUpButton()
    private let wheelSpeed = NSPopUpButton()
    private var preferences = Preferences.load()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 410), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.ui("settings.windowTitle"); window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        let root = NSView(); window.contentView = root
        bitrate.addItems(withTitles: [L10n.ui("settings.bitrate.low"), L10n.ui("settings.bitrate.balanced"), L10n.ui("settings.bitrate.high"), L10n.ui("settings.bitrate.highest")])
        let values = [8,20,40,80]; bitrate.selectItem(at: values.firstIndex(of: preferences.maxBitrateMbps) ?? 2)
        autoplay.state = preferences.autoplayNext ? .on : .off
        subtitles.state = preferences.defaultSubtitle ? .on : .off
        appearance.addItems(withTitles: [L10n.ui("settings.appearance.system"), L10n.ui("settings.appearance.light"), L10n.ui("settings.appearance.dark")])
        appearance.selectItem(at: UserDefaults.standard.integer(forKey: "luma.native.appearance"))
        wheelSpeed.addItems(withTitles: [L10n.ui("settings.wheel.slowest"), L10n.ui("settings.wheel.remote"), L10n.ui("settings.wheel.slower"), L10n.ui("settings.wheel.original")])
        wheelSpeed.selectItem(at: WheelScrollSettings.multipliers.firstIndex(of: Double(WheelScrollSettings.pixelMultiplier)) ?? 3)
        wheelSpeed.toolTip = L10n.ui("settings.wheel.help")
        for control in [bitrate, autoplay, subtitles, appearance, wheelSpeed] as [NSControl] { control.target = self; control.action = #selector(save) }
        let title = UI.label(L10n.ui("settings.title"), size: 21, weight: .semibold)
        let grid = NSGridView(views: [[UI.label(L10n.ui("settings.appearance")), appearance], [UI.label(L10n.ui("settings.bitrate")), bitrate], [UI.label(L10n.ui("settings.wheel")), wheelSpeed]])
        grid.rowSpacing = 16; grid.columnSpacing = 20
        grid.column(at: 0).xPlacement = .trailing
        let note = UI.label(L10n.ui("settings.note"), size: 12, color: .secondaryLabelColor)
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        let stack = UI.stack([title, grid, autoplay, subtitles, note], spacing: 22)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30), stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28)])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func save() {
        preferences.maxBitrateMbps = [8,20,40,80][bitrate.indexOfSelectedItem]
        preferences.autoplayNext = autoplay.state == .on
        preferences.defaultSubtitle = subtitles.state == .on
        preferences.save()
        UserDefaults.standard.set(appearance.indexOfSelectedItem, forKey: "luma.native.appearance")
        WheelScrollSettings.pixelMultiplier = CGFloat(WheelScrollSettings.multipliers[wheelSpeed.indexOfSelectedItem])
        Self.applyAppearance()
    }
    static func applyAppearance() {
        switch UserDefaults.standard.integer(forKey: "luma.native.appearance") {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
