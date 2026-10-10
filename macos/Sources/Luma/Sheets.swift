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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "连接 Emby 服务器"
        super.init(window: window)
        let root = NSView(); window.contentView = root
        let icon = NSImageView(image: NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true; icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let title = UI.label(session == nil ? "连接你的私人影院" : "管理服务器连接", size: 24, weight: .bold)
        let hint = UI.label(session.map { "当前连接：\($0.serverName)" } ?? "输入 Emby 服务器地址和你的账户。", size: 13, color: .secondaryLabelColor)
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 390).isActive = true
        address.placeholderString = "https://emby.example.com"
        address.stringValue = session?.serverURL ?? UserDefaults.standard.string(forKey: "luma.native.lastServer") ?? ""
        username.placeholderString = "用户名"
        username.stringValue = session?.userName ?? UserDefaults.standard.string(forKey: "luma.native.lastUsername") ?? ""
        password.placeholderString = "密码"
        for (field, label) in [(address, "服务器地址"), (username, "用户名"), (password, "密码")] {
            field.controlSize = .large
            field.font = .systemFont(ofSize: 13)
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 370).isActive = true
        }
        let form = UI.stack([UI.label("服务器地址", size: 12, weight: .medium), address, UI.label("用户名", size: 12, weight: .medium), username, UI.label("密码", size: 12, weight: .medium), password], spacing: 7)
        form.setCustomSpacing(14, after: address); form.setCustomSpacing(14, after: username)
        errorLabel.maximumNumberOfLines = 3; errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.widthAnchor.constraint(equalToConstant: 390).isActive = true
        let security = UI.label("登录凭据安全保存在 macOS 钥匙串，下次启动自动连接。", size: 11, color: .secondaryLabelColor)
        let stack = UI.stack([icon, title, hint, form, security, errorLabel], spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40)])
        submit.title = session == nil ? "连接" : "切换连接"; submit.bezelStyle = .rounded; submit.keyEquivalent = "\r"; submit.target = self; submit.action = #selector(connect)
        let cancel = UI.button("取消", target: self, action: #selector(closeSheet)); cancel.keyEquivalent = "\u{1b}"
        disconnect.title = "断开并忘记"; disconnect.bezelStyle = .rounded; disconnect.target = self; disconnect.action = #selector(disconnectPressed); disconnect.isHidden = session == nil
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let buttons = UI.stack([spinner, cancel, submit], vertical: false, spacing: 10)
        buttons.translatesAutoresizingMaskIntoConstraints = false; disconnect.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons); root.addSubview(disconnect)
        NSLayoutConstraint.activate([buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), disconnect.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), disconnect.centerYAnchor.constraint(equalTo: buttons.centerYAnchor)])
        window.initialFirstResponder = address
        address.nextKeyView = username; username.nextKeyView = password; password.nextKeyView = submit
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func connect() {
        // Commit the active field editor before reading or disabling the fields.
        guard window?.makeFirstResponder(nil) != false else { return }
        let server = address.stringValue; let name = username.stringValue; let secret = password.stringValue
        guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorLabel.stringValue = "请填写服务器地址和用户名。"; return }
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
        window.title = "影片详情"
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
        overview.setAccessibilityLabel("影片简介")
        overviewScroll.drawsBackground = false
        overviewScroll.borderType = .noBorder
        overviewScroll.autohidesScrollers = true
        overviewScroll.setAccessibilityLabel("完整影片简介")
        play.title = item.kind == .series ? "正在载入剧集…" : (item.positionTicks > 0 ? "继续播放" : "播放")
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
            let heading = UI.label("剧集", size: 18, weight: .semibold)
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            table.addTableColumn(NSTableColumn(identifier: .init("episodes")))
            table.headerView = nil; table.rowHeight = 45; table.style = .inset; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(episodePressed)
            table.setAccessibilityLabel("剧集列表，双击播放")
            table.onPlaySelection = { [weak self] in self?.playSelectedEpisode() }
            scroll.documentView = table
            [heading, scroll].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
            NSLayoutConstraint.activate([heading.leadingAnchor.constraint(equalTo: poster.leadingAnchor), heading.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 25), scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: poster.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: texts.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -75)])
        }
        let close = UI.button("完成", target: self, action: #selector(closeSheet)); close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false; status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(close); root.addSubview(status)
        NSLayoutConstraint.activate([close.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20), status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), status.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -16), status.centerYAnchor.constraint(equalTo: close.centerYAnchor)])
        update()
        status.stringValue = "正在获取影片信息…"
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
                    self.status.stringValue = "\(self.episodes.count) 集 · 双击一集开始播放"
                } else {
                    self.play.title = Self.playTitle(for: fullItem, episodes: [])
                    self.status.stringValue = item.id.hasPrefix("demo-") ? "预览影片 · 播放为 Sintel 示例短片" : ""
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.status.stringValue = error.localizedDescription
                if self.item.kind == .series { self.play.title = "暂无可播放剧集" }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func update() {
        titleLabel.stringValue = item.title
        metadata.stringValue = [item.originalTitle ?? "", item.metadataText].filter { !$0.isEmpty }.joined(separator: "\n")
        let description = item.overview.isEmpty ? "这部影片暂时没有简介。" : item.overview
        if overview.string != description { overview.string = description }
        poster.setImage(item.imageURL, pixels: 600)
        favorite.title = item.isFavorite ? "已收藏" : "收藏"
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
        guard let target = playbackTarget(for: item, episodes: episodes) else { return "暂无可播放剧集" }
        let action = target.positionTicks > 0 && !target.isPlayed ? "继续播放" : "播放"
        guard item.kind == .series else { return action }
        guard let number = target.episodeNumber else { return action }
        return "\(action) S\(target.seasonNumber ?? 1) · E\(number)"
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
        let number = "S\(episode.seasonNumber ?? 1) · E\(episode.episodeNumber ?? row + 1)"
        let label = UI.label("\(number)   \(episode.title)", size: 13, weight: .medium)
        let duration = UI.label(episode.isPlayed ? "已看完" : episode.durationLabel, size: 11, color: .secondaryLabelColor)
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
    private let autoplay = NSButton(checkboxWithTitle: "一集结束后，自动播放下一集", target: nil, action: nil)
    private let subtitles = NSButton(checkboxWithTitle: "优先显示默认字幕", target: nil, action: nil)
    private let appearance = NSPopUpButton()
    private let wheelSpeed = NSPopUpButton()
    private var preferences = Preferences.load()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Luma 设置"; window.isReleasedWhenClosed = false; window.center()
        super.init(window: window)
        let root = NSView(); window.contentView = root
        bitrate.addItems(withTitles: ["8 Mbps · 节省流量", "20 Mbps · 均衡", "40 Mbps · 高画质", "80 Mbps · 最高画质"])
        let values = [8,20,40,80]; bitrate.selectItem(at: values.firstIndex(of: preferences.maxBitrateMbps) ?? 2)
        autoplay.state = preferences.autoplayNext ? .on : .off
        subtitles.state = preferences.defaultSubtitle ? .on : .off
        appearance.addItems(withTitles: ["跟随系统", "浅色", "深色"])
        appearance.selectItem(at: UserDefaults.standard.integer(forKey: "luma.native.appearance"))
        wheelSpeed.addItems(withTitles: ["更慢", "较慢 · 适合远程", "稍慢", "原始速度"])
        wheelSpeed.selectItem(at: WheelScrollSettings.multipliers.firstIndex(of: Double(WheelScrollSettings.pixelMultiplier)) ?? 3)
        wheelSpeed.toolTip = "调整远程控制等像素滚轮的移动距离；触控板手势和系统惯性保持原样。"
        for control in [bitrate, autoplay, subtitles, appearance, wheelSpeed] as [NSControl] { control.target = self; control.action = #selector(save) }
        let title = UI.label("恰到好处的观影体验", size: 21, weight: .semibold)
        let grid = NSGridView(views: [[UI.label("外观"), appearance], [UI.label("最高码率"), bitrate], [UI.label("滚轮速度"), wheelSpeed]])
        grid.rowSpacing = 16; grid.columnSpacing = 20
        grid.column(at: 0).xPlacement = .trailing
        let note = UI.label("画质取决于片源、网络和服务器的转码能力。\n设置会自动保存。", size: 12, color: .secondaryLabelColor)
        note.maximumNumberOfLines = 3
        let stack = UI.stack([title, grid, autoplay, subtitles, note], spacing: 22)
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
