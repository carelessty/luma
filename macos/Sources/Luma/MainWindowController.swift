import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    let service: MediaService
    private let sidebar = SidebarController()
    private let split = NSSplitViewController()
    private let content = NSViewController()
    private let titleLabel = UI.label("现在观看", size: 30, weight: .bold)
    private let subtitleLabel = UI.label("好故事，随时继续。", size: 13, color: .secondaryLabelColor)
    private let statusLabel = UI.label(size: 12, color: .secondaryLabelColor)
    private let body = NSView()
    private let spinner = NSProgressIndicator()
    private let search = NSSearchField()
    private let sort = NSPopUpButton()
    private var destination = SidebarController.primary[0]
    private var session: Session?
    private var homeData: HomeData?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var libraryItems: [MediaItem] = []
    private var libraryQuery: LibraryQuery?
    private var nextOffset = 0
    private var loadingMore = false
    private var reachedLibraryEnd = false
    private var favoriteRequests: Set<String> = []
    private var total = 0
    private var grid: MediaGridController?
    private var homeGrids: [MediaGridController] = []
    private var hero: HeroView?
    private var nextButton: NSButton?
    private var connectSheet: ConnectController?
    private var detailSheet: DetailController?
    private var settingsWindow: SettingsController?
    private lazy var player: PlayerWindowController = {
        let controller = PlayerWindowController(service: service)
        controller.onPlaybackStopped = { [weak self] in self?.reload() }
        controller.onNextEpisode = { [weak self] item in self?.playNext(after: item) }
        return controller
    }()
    init(service: MediaService = MediaService()) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Luma"
        window.subtitle = "你的私人影院"
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 880, height: 640)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LumaNativeMain")
        window.center()
        super.init(window: window)
        configureContent()
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 190
        side.maximumThickness = 280
        side.canCollapse = true
        side.preferredThicknessFraction = 0.18
        split.addSplitViewItem(side)
        let main = NSSplitViewItem(viewController: content)
        main.minimumThickness = 650
        split.addSplitViewItem(main)
        window.contentViewController = split
        let toolbar = NSToolbar(identifier: "LumaToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        sidebar.onSelect = { [weak self] destination in
            guard let self else { return }
            self.destination = destination
            self.search.stringValue = ""
            self.reload()
        }
        sidebar.onConnect = { [weak self] in self?.showConnect() }
        if !window.setFrameUsingName("LumaNativeMain"), let screen = NSScreen.main {
            let available = screen.visibleFrame
            let size = NSSize(width: min(1260, available.width - 40), height: min(850, available.height - 24))
            window.setFrame(NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func configureContent() {
        content.view = NSView()
        sort.addItems(withTitles: ["最近添加", "名称", "发行年份", "评分"])
        sort.target = self; sort.action = #selector(sortChanged)
        sort.setAccessibilityLabel("排序方式")
        sort.isHidden = true
        let heading = UI.stack([titleLabel, subtitleLabel], spacing: 6)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        [heading, sort, body, statusLabel, spinner].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.view.addSubview($0) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.view.safeAreaLayoutGuide.topAnchor, constant: 24), heading.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 30), heading.trailingAnchor.constraint(lessThanOrEqualTo: sort.leadingAnchor, constant: -20),
            sort.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -30), sort.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 25), body.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 30), body.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -30), body.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),
            statusLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor), statusLabel.bottomAnchor.constraint(equalTo: content.view.bottomAnchor, constant: -14),
            spinner.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 9), spinner.trailingAnchor.constraint(lessThanOrEqualTo: content.view.trailingAnchor, constant: -20), spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor), spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14)
        ])
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .init("search"), .init("refresh"), .init("account")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id.rawValue == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            search.placeholderString = "搜索你的资料库"
            search.delegate = self
            search.sendsSearchStringImmediately = true
            search.setAccessibilityLabel("搜索资料库")
            item.searchField = search
            return item
        }
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "refresh" { item.label = "刷新"; item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新"); item.target = self; item.action = #selector(refreshPressed) }
        else if id.rawValue == "account" { item.label = "连接服务器"; item.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "管理连接"); item.target = self; item.action = #selector(connectPressed) }
        else { return nil }
        // Standard bordered items participate in the system's Liquid Glass
        // toolbar grouping on current macOS, and retain native older styling.
        item.isBordered = true
        return item
    }
    func focusSearch() { window?.makeFirstResponder(search) }
    func toggleSidebar() { split.toggleSidebar(nil) }
    func selectDestination(_ index: Int) { sidebar.select(index) }
    @objc private func refreshPressed() { reload() }
    @objc private func connectPressed() { showConnect() }
    @objc private func sortChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) {
        searchTask?.cancel()
        // Invalidate an in-flight page immediately; a pending search must not
        // append results for the old query during the debounce interval.
        loadTask?.cancel()
        generation += 1
        nextButton?.isEnabled = false
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            self?.searchTask = nil
            self?.reload()
        }
    }
    private func makeQuery(offset: Int = 0) -> LibraryQuery {
        let sorting = ["DateCreated", "SortName", "ProductionYear", "CommunityRating"]
        let term = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryQuery(kind: ["movie", "series"].contains(destination.key) ? destination.key : nil, parentID: destination.parentID, search: term.isEmpty ? nil : term, favorites: destination.key == "favorites" ? true : nil, startIndex: offset, limit: 40, sortBy: sorting[max(0, sort.indexOfSelectedItem)], sortOrder: sort.indexOfSelectedItem == 1 ? "Ascending" : "Descending")
    }
    func reload() {
        searchTask?.cancel()
        loadTask?.cancel()
        generation += 1
        libraryQuery = nil
        loadingMore = false
        reachedLibraryEnd = false
        let current = generation
        let searching = !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isHome = destination.key == "home" && !searching
        titleLabel.stringValue = searching ? "搜索结果" : destination.title
        subtitleLabel.stringValue = searching ? "查找“\(search.stringValue)”" : "好故事，随时继续。"
        sort.isHidden = isHome
        statusLabel.stringValue = "正在载入…"
        spinner.startAnimation(nil)
        clearBody()
        let query = makeQuery()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let currentSession = try await self.service.restoreSession()
                guard current == self.generation, !Task.isCancelled else { return }
                self.session = currentSession
                self.window?.subtitle = currentSession?.serverName ?? "预览模式"
                self.sidebar.update(session: currentSession, views: self.homeData?.views ?? [])
                if isHome {
                    let data = try await self.service.home()
                    guard current == self.generation, !Task.isCancelled else { return }
                    self.homeData = data
                    self.sidebar.update(session: currentSession, views: data.views)
                    self.renderHome(data)
                } else {
                    let page = try await self.service.library(query: query)
                    guard current == self.generation, !Task.isCancelled else { return }
                    self.libraryItems = page.items; self.total = page.total
                    self.libraryQuery = query
                    self.nextOffset = page.items.count
                    self.reachedLibraryEnd = page.items.isEmpty || self.nextOffset >= page.total
                    self.renderLibrary()
                }
                self.spinner.stopAnimation(nil)
            } catch {
                guard current == self.generation, !Task.isCancelled else { return }
                let savedSession = try? await self.service.session()
                guard current == self.generation, !Task.isCancelled else { return }
                self.session = savedSession
                self.window?.subtitle = savedSession?.serverName ?? "未连接"
                self.sidebar.update(session: savedSession, views: savedSession == nil ? [] : (self.homeData?.views ?? []))
                self.spinner.stopAnimation(nil)
                let needsLogin = (error as? ServiceError)?.code == "AUTH_REQUIRED"
                self.renderMessage(title: needsLogin ? "请重新登录" : "暂时无法载入", message: error.localizedDescription, symbol: needsLogin ? "person.crop.circle.badge.exclamationmark" : "wifi.exclamationmark", retry: true, reconnect: needsLogin)
                self.statusLabel.stringValue = savedSession == nil ? "载入失败" : "暂时无法连接 · 已保留上次登录"
            }
        }
    }
    private func clearBody() {
        body.subviews.forEach { $0.removeFromSuperview() }
        if let grid { grid.removeFromParent() }; grid = nil
        homeGrids.forEach { $0.removeFromParent() }; homeGrids = []
        hero = nil
        nextButton = nil
    }
    private func wire(_ grid: MediaGridController) {
        grid.onOpen = { [weak self] in self?.showDetail($0) }
        grid.onPlay = { [weak self] in self?.play($0) }
        grid.onFavorite = { [weak self] in self?.toggleFavorite($0) }
    }
    private func renderHome(_ data: HomeData) {
        clearBody()
        subtitleLabel.stringValue = session == nil ? "先逛逛，再连接你的私人影院。" : "欢迎回来，\(session!.userName)。"
        statusLabel.stringValue = data.notice ?? (session == nil ? "预览模式 · 虚构影片 · 播放为 Sintel 示例短片" : "已连接到 \(session!.serverName)")
        guard data.featured != nil || [data.resume, data.latest, data.movies, data.series].contains(where: { !$0.isEmpty }) else {
            renderMessage(title: "你的影院，静候开场", message: "服务器中还没有可浏览的影片。添加媒体后，按 ⌘R 刷新。", symbol: "film", retry: true)
            return
        }
        let scroll = MediaScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = FlippedView()
        scroll.documentView = document
        UI.pin(scroll, to: body)
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let stack = UI.stack([], spacing: 27)
        UI.pin(stack, to: document)
        if let featured = data.featured {
            let hero = HeroView()
            self.hero = hero
            hero.configure(featured, demo: session == nil)
            hero.onPlay = { [weak self] in self?.play($0) }; hero.onDetail = { [weak self] in self?.showDetail($0) }
            stack.addArrangedSubview(hero)
            hero.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            hero.heightAnchor.constraint(equalToConstant: 320).isActive = true
        }
        for (title, items, landscape) in [("继续观看", data.resume, true), ("最近添加", data.latest, false), ("电影之夜", data.movies, false), ("值得追的剧", data.series, false)] where !items.isEmpty {
            let heading = UI.stack([UI.label(title, size: 20, weight: .bold), UI.label("\(items.count) 部", size: 12, color: .tertiaryLabelColor)], vertical: false, spacing: 10)
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(12, after: heading)
            let grid = MediaGridController()
            grid.horizontal = true; grid.landscape = landscape
            wire(grid); content.addChild(grid)
            stack.addArrangedSubview(grid.view)
            grid.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            grid.view.heightAnchor.constraint(equalToConstant: landscape ? 220 : 322).isActive = true
            grid.setItems(items)
            homeGrids.append(grid)
        }
    }
    private func renderLibrary() {
        clearBody()
        subtitleLabel.stringValue = librarySubtitle
        statusLabel.stringValue = libraryItems.isEmpty ? "没有匹配的影片" : "已显示 \(libraryItems.count) / \(total) 部 · 双击查看详情，空格播放"
        guard !libraryItems.isEmpty else {
            renderMessage(title: destination.key == "favorites" ? "留住喜欢的故事" : "没有找到影片", message: destination.key == "favorites" ? "在影片详情中点击收藏，喜欢的电影和剧集就会出现在这里。" : "试试其他关键词，或选择另一个资料库。", symbol: destination.key == "favorites" ? "heart" : "magnifyingglass", retry: false)
            return
        }
        let grid = MediaGridController(); wire(grid); content.addChild(grid)
        self.grid = grid
        let more = UI.button("载入更多", symbol: "plus", target: self, action: #selector(loadMore))
        more.isHidden = reachedLibraryEnd
        nextButton = more
        [grid.view, more].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; body.addSubview($0) }
        NSLayoutConstraint.activate([grid.view.leadingAnchor.constraint(equalTo: body.leadingAnchor), grid.view.trailingAnchor.constraint(equalTo: body.trailingAnchor), grid.view.topAnchor.constraint(equalTo: body.topAnchor), grid.view.bottomAnchor.constraint(equalTo: more.topAnchor, constant: -6), more.centerXAnchor.constraint(equalTo: body.centerXAnchor), more.bottomAnchor.constraint(equalTo: body.bottomAnchor), more.heightAnchor.constraint(equalToConstant: more.isHidden ? 0 : 28)])
        grid.setItems(libraryItems)
    }
    private var librarySubtitle: String {
        let kind = libraryQuery?.kind == "series" ? "部剧集" : libraryQuery?.kind == "movie" ? "部电影" : "部影片与剧集"
        return "\(total) \(kind)\(session == nil ? " · 预览资料库" : "")"
    }
    @objc private func loadMore() {
        guard !loadingMore, !reachedLibraryEnd, var query = libraryQuery else { return }
        loadingMore = true
        nextButton?.isEnabled = false; spinner.startAnimation(nil)
        let current = generation
        query.startIndex = nextOffset
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.service.library(query: query)
                guard current == self.generation, !Task.isCancelled else { return }
                let existing = Set(self.libraryItems.map(\.id))
                let additions = page.items.filter { !existing.contains($0.id) }
                self.nextOffset += page.items.count
                self.libraryItems.append(contentsOf: additions)
                self.total = page.total
                self.reachedLibraryEnd = additions.isEmpty || self.nextOffset >= page.total
                self.grid?.setItems(self.libraryItems)
                self.nextButton?.isHidden = self.reachedLibraryEnd
                self.statusLabel.stringValue = "已显示 \(self.libraryItems.count) / \(self.total) 部"
            } catch { if current == self.generation, !Task.isCancelled { self.showError(error) } }
            if current == self.generation { self.loadingMore = false; self.nextButton?.isEnabled = true; self.spinner.stopAnimation(nil) }
        }
    }
    private func renderMessage(title: String, message: String, symbol: String, retry: Bool, reconnect: Bool = false) {
        clearBody()
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 46).isActive = true; icon.heightAnchor.constraint(equalToConstant: 46).isActive = true
        let label = UI.label(message, size: 13, color: .secondaryLabelColor)
        label.maximumNumberOfLines = 4; label.alignment = .center; label.lineBreakMode = .byWordWrapping
        let stack = UI.stack([icon, UI.label(title, size: 23, weight: .semibold), label], spacing: 14)
        stack.alignment = .centerX
        if reconnect { stack.addArrangedSubview(UI.button("重新登录…", target: self, action: #selector(connectPressed))) }
        else if retry { stack.addArrangedSubview(UI.button("重新载入", target: self, action: #selector(refreshPressed))) }
        stack.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: body.centerXAnchor), stack.centerYAnchor.constraint(equalTo: body.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -80), label.widthAnchor.constraint(lessThanOrEqualToConstant: 430)])
    }
    func showConnect() {
        guard window?.attachedSheet == nil else { return }
        let controller = ConnectController(service: service, session: session)
        controller.onWillChangeSession = { [weak self] in
            await self?.player.stopAndWait()
            self?.player.close()
            await ImagePipeline.shared.removeAll()
        }
        controller.onComplete = { [weak self] in
            guard let self else { return }
            self.homeData = nil
            self.destination = SidebarController.primary[0]
            self.search.stringValue = ""
            self.sidebar.select(0)
            self.reload()
        }
        connectSheet = controller
        if let parent = window, let sheet = controller.window { parent.beginSheet(sheet) }
    }
    func showSettings() { if settingsWindow == nil { settingsWindow = SettingsController() }; settingsWindow?.showWindow(nil); settingsWindow?.window?.makeKeyAndOrderFront(nil) }
    func stopPlayback() { player.stop() }
    func stopPlaybackAndWait() async { await player.stopAndWait() }
    private func showDetail(_ item: MediaItem) {
        guard window?.attachedSheet == nil else { return }
        let controller = DetailController(item: item, service: service)
        let requestedSession = session
        controller.onPlay = { [weak self] in self?.play($0) }
        controller.onChanged = { [weak self] item in
            guard self?.session == requestedSession else { return }
            self?.updateFavorite(item)
        }
        detailSheet = controller
        if let parent = window, let sheet = controller.window { parent.beginSheet(sheet) }
    }
    private func play(_ item: MediaItem) {
        if item.kind == .series { showDetail(item); return }
        player.play(item, preferences: Preferences.load())
    }
    private func playNext(after item: MediaItem) {
        guard let id = item.seriesID else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let episodes = try await self.service.episodes(id: id)
                if let index = episodes.firstIndex(where: { $0.id == item.id }), episodes.indices.contains(index + 1) { self.play(episodes[index + 1]) }
            } catch { self.showError(error) }
        }
    }
    private func toggleFavorite(_ item: MediaItem) {
        guard favoriteRequests.insert(item.id).inserted else { return }
        let requestedSession = session
        Task { [weak self] in
            guard let self else { return }
            defer { self.favoriteRequests.remove(item.id) }
            do {
                try await self.service.favorite(id: item.id, value: !item.isFavorite)
                guard self.session == requestedSession else { return }
                var updated = item
                updated.isFavorite.toggle()
                self.updateFavorite(updated)
            } catch { if self.session == requestedSession { self.showError(error) } }
        }
    }
    private func updateFavorite(_ item: MediaItem) {
        func updated(_ items: [MediaItem]) -> [MediaItem] {
            items.map { original in
                guard original.id == item.id else { return original }
                var value = original; value.isFavorite = item.isFavorite
                return value
            }
        }
        if var data = homeData {
            data.resume = updated(data.resume); data.latest = updated(data.latest)
            data.movies = updated(data.movies); data.series = updated(data.series)
            if data.featured?.id == item.id {
                data.featured?.isFavorite = item.isFavorite
                if let featured = data.featured { hero?.configure(featured, demo: session == nil) }
            }
            homeData = data
        }
        for shelf in homeGrids { shelf.updateFavorite(id: item.id, value: item.isFavorite) }
        let removesItem = libraryQuery?.favorites == true && !item.isFavorite
        let wasPresent = libraryItems.contains { $0.id == item.id }
        libraryItems = updated(libraryItems)
        if removesItem {
            libraryItems.removeAll { $0.id == item.id }
            if wasPresent { total = max(0, total - 1); nextOffset = max(0, nextOffset - 1) }
        }
        grid?.updateFavorite(id: item.id, value: item.isFavorite, remove: removesItem)
        if grid != nil {
            subtitleLabel.stringValue = librarySubtitle
            statusLabel.stringValue = "已显示 \(libraryItems.count) / \(total) 部 · 双击查看详情，空格播放"
            if libraryItems.isEmpty { renderLibrary() }
        }
    }
    private func showError(_ error: Error) { let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = error.localizedDescription; if let window { alert.beginSheetModal(for: window) } }
}
