import Foundation

/// Fictional media used only when the application visibly indicates demo mode.
struct DemoCatalog {
    private let defaults: UserDefaults
    private var favorites: Set<String>
    private static let favoritesKey = "luma.native.demo.favorites.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        favorites = Set(defaults.stringArray(forKey: Self.favoritesKey) ?? ["demo-dune", "demo-mountains"])
    }

    private static func image(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Media")
            ?? Bundle.main.url(forResource: name, withExtension: "jpg")
    }

    static let catalog: [MediaItem] = [
        MediaItem(id: "demo-voyage", title: "星际漫游", originalTitle: "Interstellar Voyage", overview: "在地球最后一座灯塔熄灭之前，一名宇航员接到了来自遥远星系的讯号。她踏上穿越星海的旅程，寻找人类失落的家园，也寻找关于自己的答案。", year: 2025, durationTicks: 148 * 600_000_000, rating: 8.9, genres: ["科幻", "冒险", "剧情"], imageURL: image("poster-4"), backdropURL: image("hero"), tagline: "越过星海，寻找归途。"),
        MediaItem(id: "demo-dune", title: "沙丘之旅", originalTitle: "Beyond the Dunes", overview: "无边的沙海隐藏着古老文明的秘密。一位年轻的旅人跟随风的方向，走向一场关乎家园与信念的远征。", year: 2024, durationTicks: 132 * 600_000_000, rating: 8.6, genres: ["科幻", "冒险"], imageURL: image("poster-1"), backdropURL: image("poster-1"), positionTicks: 44_460_000_000, tagline: "每一粒沙，都记得来时的路。"),
        MediaItem(id: "demo-tokyo", title: "东京夜行", originalTitle: "Tokyo After Dark", kind: .series, overview: "霓虹灯映照着城市的另一面。一个夜班摄影师在最后一班列车上，意外卷入一连串看似无关的故事。每一个陌生人，都藏着一个等待被发现的秘密。", year: 2025, durationTicks: 46 * 600_000_000, rating: 8.4, genres: ["悬疑", "都市", "剧情"], imageURL: image("poster-2"), backdropURL: image("poster-2"), positionTicks: 17_660_000_000, tagline: "午夜之后，故事才刚刚开始。", childCount: 8),
        MediaItem(id: "demo-mountains", title: "群山之间", originalTitle: "Between the Mountains", overview: "在远离喧嚣的山间，一位返乡的建筑师与童年的好友再次相遇。他们沿着一条旧山路，重新认识故乡，也重新理解生命中那些未曾说出口的告别。", year: 2024, durationTicks: 108 * 600_000_000, rating: 8.7, genres: ["剧情", "旅行"], imageURL: image("poster-3"), backdropURL: image("poster-3"), positionTicks: 18_140_000_000, tagline: "有些答案，藏在寂静的山里。"),
        MediaItem(id: "demo-ocean", title: "蔚蓝深处", originalTitle: "Into the Blue", overview: "跟随一支深海探险队，潜入阳光无法抵达的水域。从微小的发光生命到宏伟的海底峡谷，一段关于海洋、时间与生命的旅程徐徐展开。", year: 2025, durationTicks: 96 * 600_000_000, rating: 9.1, genres: ["纪录片", "自然"], imageURL: image("poster-5"), backdropURL: image("poster-5"), tagline: "在世界的深处，发现生命的光。"),
        MediaItem(id: "demo-forest", title: "最后的森林", originalTitle: "The Last Forest", kind: .series, overview: "从第一缕晨光到星光下的林间，一位自然记录者守候在古老森林里，记录四季流转中的生命奇迹，以及守护这片土地的人们。", year: 2023, durationTicks: 52 * 600_000_000, rating: 8.8, genres: ["纪录片", "自然", "探索"], imageURL: image("poster-6"), backdropURL: image("poster-6"), tagline: "听见森林，也听见自己。", childCount: 6)
    ]

    private func copy(_ original: MediaItem) -> MediaItem {
        var item = original
        item.isFavorite = favorites.contains(item.id)
        return item
    }

    func home() -> HomeData {
        let items = Self.catalog.map(copy)
        return HomeData(featured: items.first, resume: items.filter { $0.progress > 0 && $0.progress < 100 }, latest: [items[1], items[2], items[3], items[0], items[4], items[5]], movies: items.filter { $0.kind == .movie }, series: items.filter { $0.kind == .series }, views: [
            MediaItem(id: "demo-library-movies", title: "小影院", kind: .collection),
            MediaItem(id: "demo-library-series", title: "剧集时光", kind: .collection)
        ])
    }

    func library(query: LibraryQuery) -> LibraryPage {
        let words = (query.search ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var items = Self.catalog.map(copy).filter { item in
            if let kind = query.kind, kind != "all", item.kind.rawValue != kind { return false }
            if query.parentID == "demo-library-movies", item.kind != .movie { return false }
            if query.parentID == "demo-library-series", item.kind != .series { return false }
            if query.favorites == true, !item.isFavorite { return false }
            let text = "\(item.title) \(item.originalTitle ?? "") \(item.overview) \(item.genres.joined(separator: " ")) \(item.year.map(String.init) ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let ascending = query.sortOrder == "Ascending"
        if query.sortBy == "SortName" {
            items.sort { ascending ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        } else if query.sortBy == "ProductionYear" {
            items.sort { ascending ? ($0.year ?? 0) < ($1.year ?? 0) : ($0.year ?? 0) > ($1.year ?? 0) }
        } else if query.sortBy == "CommunityRating" {
            items.sort { ascending ? ($0.rating ?? 0) < ($1.rating ?? 0) : ($0.rating ?? 0) > ($1.rating ?? 0) }
        } else if ascending {
            items.reverse()
        }
        let total = items.count
        let start = min(total, max(0, query.startIndex ?? 0))
        let end = min(total, start + min(200, max(1, query.limit ?? 60)))
        return LibraryPage(items: Array(items[start..<end]), total: total)
    }

    func episodes(id: String) -> [MediaItem] {
        guard let series = Self.catalog.first(where: { $0.id == id && $0.kind == .series }) else { return [] }
        let titles = id == "demo-tokyo" ? ["最后一班列车", "陌生来电", "雨夜来客", "消失的照片", "灯火阑珊", "城市边缘", "天亮之前", "归途"] : ["森林苏醒", "隐秘的世界", "树冠之上", "雨季来临", "夜的声音", "生生不息"]
        return titles.enumerated().map { index, title in
            var episode = series
            episode.id = "\(series.id)-episode-\(index + 1)"
            episode.title = title
            episode.originalTitle = nil
            episode.kind = .episode
            episode.seriesID = series.id
            episode.seriesTitle = series.title
            episode.seasonNumber = 1
            episode.episodeNumber = index + 1
            episode.childCount = nil
            episode.positionTicks = index == 0 ? series.positionTicks : 0
            return copy(episode)
        }
    }

    func item(id: String) throws -> MediaItem {
        if let item = Self.catalog.first(where: { $0.id == id }) { return copy(item) }
        let series = id.components(separatedBy: "-episode-").first ?? ""
        if let item = episodes(id: series).first(where: { $0.id == id }) { return item }
        throw ServiceError(code: "NOT_FOUND", message: "找不到这个演示条目。")
    }

    mutating func favorite(id: String, value: Bool) throws {
        _ = try item(id: id)
        if value { favorites.insert(id) } else { favorites.remove(id) }
        defaults.set(Array(favorites).sorted(), forKey: Self.favoritesKey)
    }

    func playback(id: String) throws -> PlaybackInfo {
        _ = try item(id: id)
        return PlaybackInfo(isDemo: true, label: "演示片段 · Sintel（Blender Foundation）", url: URL(string: "https://media.w3.org/2010/05/sintel/trailer.mp4")!, itemID: id, mediaSourceID: "demo-sintel-trailer", playSessionID: "demo", playMethod: "DirectPlay", mimeType: "video/mp4", startTicks: 0, subtitles: [], audioTracks: [])
    }
}
