import AppKit
import Testing
@testable import Luma

private struct EmptyNavigationSessionStore: SessionStore {
    func load() throws -> StoredSession? { nil }
    func save(_ value: StoredSession) throws {}
    func clear() throws {}
}

private final class NavigationProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let url = request.url!
        let path = url.path
        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        let start = Int(query["StartIndex"] ?? "0") ?? 0
        let term = query["SearchTerm"] ?? ""
        let body: Any
        if path.hasSuffix("AuthenticateByName") {
            body = ["AccessToken": "fixture-token", "User": ["Id": "fixture-user", "Name": "Fixture User"]]
        } else if path.hasSuffix("System/Info/Public") {
            body = ["ServerName": "Navigation Fixture"]
        } else if path.hasSuffix("/Views") || path.hasSuffix("/Resume") {
            body = ["Items": [], "TotalRecordCount": 0]
        } else if path.hasSuffix("/Latest") {
            body = []
        } else {
            let count = term.isEmpty ? 41 : 3
            let end = min(count, start + (Int(query["Limit"] ?? "40") ?? 40))
            let items = (min(start, count)..<end).map { index -> [String: Any] in
                ["Id": "\(term.isEmpty ? "movie" : term)-\(index)", "Name": "\(term.isEmpty ? "Movie" : term) \(index)", "Type": "Movie"]
            }
            body = ["Items": items, "TotalRecordCount": count]
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        let delay = start > 0 ? 0.6 : 0.01
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
    static func reset() { lock.lock(); requests = []; lock.unlock() }
    static func queries() -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return requests.compactMap { request in
            guard let url = request.url, url.path.hasSuffix("/Items") else { return nil }
            return Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        }
    }
}

@MainActor
@Suite(.serialized)
struct NavigationTests {
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(condition())
    }

    @Test func seriesActionResumesAnUnfinishedEpisodeAndNamesTheActualTarget() {
        let series = MediaItem(id: "series", title: "Series", kind: .series)
        let episodes = [
            MediaItem(id: "first", title: "First", kind: .episode, seasonNumber: 1, episodeNumber: 1),
            MediaItem(id: "second", title: "Second", kind: .episode, positionTicks: 500, seasonNumber: 1, episodeNumber: 2),
            MediaItem(id: "third", title: "Third", kind: .episode, positionTicks: 300, isPlayed: true, seasonNumber: 1, episodeNumber: 3)
        ]
        #expect(DetailController.playbackTarget(for: series, episodes: episodes)?.id == "second")
        #expect(DetailController.playTitle(for: series, episodes: episodes) == "继续播放 S1 · E2")
        #expect(DetailController.playbackTarget(for: series, episodes: []) == nil)
    }

    @Test func detailDisablesUnavailableActionsUntilTheItemAndEpisodesArrive() async throws {
        _ = NSApplication.shared
        let name = "LumaNavigationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = MediaService(defaults: defaults, sessionStore: EmptyNavigationSessionStore())
        let item = try #require(DemoCatalog.catalog.first(where: { $0.kind == .series }))
        let controller = DetailController(item: item, service: service)
        let window = try #require(controller.window)
        defer { window.close() }
        let root = try #require(window.contentView)
        let buttons = descendants(of: root).compactMap { $0 as? NSButton }
        let play = try #require(buttons.first { $0.title == "正在载入剧集…" })
        let favorite = try #require(buttons.first { $0.title == "收藏" || $0.title == "已收藏" })
        #expect(!play.isEnabled)
        #expect(!favorite.isEnabled)
        for _ in 0..<100 where !play.isEnabled { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(play.isEnabled)
        #expect(favorite.isEnabled)
        #expect(play.title == "继续播放 S1 · E1")

        var changed: MediaItem?
        controller.onChanged = { changed = $0 }
        favorite.performClick(nil)
        #expect(!favorite.isEnabled)
        for _ in 0..<100 where changed == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(changed?.id == item.id)
        #expect(changed?.isFavorite == true)
        #expect(favorite.title == "已收藏")
    }

    @Test func favoriteUpdatesKeepGridScrollAndSelectionAndCanRemoveOneFavorite() throws {
        _ = NSApplication.shared
        let grid = MediaGridController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = grid
        defer { window.close() }
        let items = (0..<70).map { MediaItem(id: "movie-\($0)", title: "Movie \($0)") }
        grid.setItems(items)
        window.contentView?.layoutSubtreeIfNeeded()
        grid.collection.layoutSubtreeIfNeeded()
        grid.scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        grid.scroll.reflectScrolledClipView(grid.scroll.contentView)
        let originalOffset = grid.scroll.contentView.bounds.origin
        let selected = IndexPath(item: 10, section: 0)
        grid.collection.selectionIndexPaths = [selected]
        grid.updateFavorite(id: "movie-10", value: true)
        #expect(grid.items[10].isFavorite)
        #expect(grid.scroll.contentView.bounds.origin == originalOffset)
        #expect(grid.collection.selectionIndexPaths == [selected])
        grid.updateFavorite(id: "movie-10", value: false, remove: true)
        #expect(grid.items.count == 69)
        #expect(!grid.items.contains { $0.id == "movie-10" })
        #expect(grid.scroll.contentView.bounds.origin == originalOffset)
    }

    @Test func longOverviewRemainsFullyReadableInItsScrollView() throws {
        _ = NSApplication.shared
        let item = MediaItem(id: "long-overview", title: "A Long Story", overview: String(repeating: "这是一段需要完整展示的影片简介。", count: 160))
        let controller = DetailController(item: item, service: MediaService(sessionStore: EmptyNavigationSessionStore()))
        let window = try #require(controller.window)
        defer { window.close() }
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        let text = try #require(descendants(of: root).compactMap { $0 as? NSTextView }.first)
        let scroll = try #require(text.enclosingScrollView)
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        #expect(text.string == item.overview)
        #expect(!text.isEditable)
        #expect(text.isSelectable)
        #expect(scroll.hasVerticalScroller)
        #expect(text.frame.height > scroll.contentView.bounds.height)
        #expect(scroll.frame.maxY < root.bounds.maxY - 55)
    }

    @Test func searchingDuringPaginationCannotAppendTheOldPageOrPageTheNewQueryEarly() async throws {
        _ = NSApplication.shared
        NavigationProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NavigationProtocol.self]
        let name = "LumaNavigationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = MediaService(urlSession: URLSession(configuration: configuration), defaults: defaults, sessionStore: EmptyNavigationSessionStore())
        _ = try await service.connect(serverURL: "https://navigation.invalid", username: "fixture", password: "fixture")
        let controller = MainWindowController(service: service)
        let window = try #require(controller.window)
        defer { window.close() }
        let root = try #require(window.contentView)
        controller.selectDestination(1)
        func mediaGrid() -> MediaGridController? {
            descendants(of: root).compactMap { $0 as? NSCollectionView }.compactMap { $0.dataSource as? MediaGridController }.first
        }
        try await waitUntil { mediaGrid()?.items.count == 40 }
        let more = try #require(descendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == "载入更多" })
        let search = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first?.searchField)
        #expect(more.isEnabled)
        more.performClick(nil)
        try await waitUntil { NavigationProtocol.queries().contains { $0["StartIndex"] == "40" } }

        search.stringValue = "new"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        #expect(!more.isEnabled)
        more.performClick(nil)
        try await waitUntil { mediaGrid()?.items.first?.id == "new-0" }
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(mediaGrid()?.items.map(\.id) == ["new-0", "new-1", "new-2"])
        #expect(!NavigationProtocol.queries().contains { $0["SearchTerm"] == "new" && $0["StartIndex"] == "40" })
    }
}
