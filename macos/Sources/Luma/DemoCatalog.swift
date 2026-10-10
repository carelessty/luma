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
        MediaItem(id: "demo-voyage", title: L10n.service("demo.voyage.title"), originalTitle: "Interstellar Voyage", overview: L10n.service("demo.voyage.overview"), year: 2025, durationTicks: 148 * 600_000_000, rating: 8.9, genres: [L10n.service("demo.genre.scifi"), L10n.service("demo.genre.adventure"), L10n.service("demo.genre.drama")], imageURL: image("poster-4"), backdropURL: image("hero"), tagline: L10n.service("demo.voyage.tagline")),
        MediaItem(id: "demo-dune", title: L10n.service("demo.dune.title"), originalTitle: "Beyond the Dunes", overview: L10n.service("demo.dune.overview"), year: 2024, durationTicks: 132 * 600_000_000, rating: 8.6, genres: [L10n.service("demo.genre.scifi"), L10n.service("demo.genre.adventure")], imageURL: image("poster-1"), backdropURL: image("poster-1"), positionTicks: 44_460_000_000, tagline: L10n.service("demo.dune.tagline")),
        MediaItem(id: "demo-tokyo", title: L10n.service("demo.tokyo.title"), originalTitle: "Tokyo After Dark", kind: .series, overview: L10n.service("demo.tokyo.overview"), year: 2025, durationTicks: 46 * 600_000_000, rating: 8.4, genres: [L10n.service("demo.genre.mystery"), L10n.service("demo.genre.urban"), L10n.service("demo.genre.drama")], imageURL: image("poster-2"), backdropURL: image("poster-2"), positionTicks: 17_660_000_000, tagline: L10n.service("demo.tokyo.tagline"), childCount: 8),
        MediaItem(id: "demo-mountains", title: L10n.service("demo.mountains.title"), originalTitle: "Between the Mountains", overview: L10n.service("demo.mountains.overview"), year: 2024, durationTicks: 108 * 600_000_000, rating: 8.7, genres: [L10n.service("demo.genre.drama"), L10n.service("demo.genre.travel")], imageURL: image("poster-3"), backdropURL: image("poster-3"), positionTicks: 18_140_000_000, tagline: L10n.service("demo.mountains.tagline")),
        MediaItem(id: "demo-ocean", title: L10n.service("demo.ocean.title"), originalTitle: "Into the Blue", overview: L10n.service("demo.ocean.overview"), year: 2025, durationTicks: 96 * 600_000_000, rating: 9.1, genres: [L10n.service("demo.genre.documentary"), L10n.service("demo.genre.nature")], imageURL: image("poster-5"), backdropURL: image("poster-5"), tagline: L10n.service("demo.ocean.tagline")),
        MediaItem(id: "demo-forest", title: L10n.service("demo.forest.title"), originalTitle: "The Last Forest", kind: .series, overview: L10n.service("demo.forest.overview"), year: 2023, durationTicks: 52 * 600_000_000, rating: 8.8, genres: [L10n.service("demo.genre.documentary"), L10n.service("demo.genre.nature"), L10n.service("demo.genre.exploration")], imageURL: image("poster-6"), backdropURL: image("poster-6"), tagline: L10n.service("demo.forest.tagline"), childCount: 6)
    ]

    private func copy(_ original: MediaItem) -> MediaItem {
        var item = original
        item.isFavorite = favorites.contains(item.id)
        return item
    }

    func home() -> HomeData {
        let items = Self.catalog.map(copy)
        return HomeData(featured: items.first, resume: items.filter { $0.progress > 0 && $0.progress < 100 }, latest: [items[1], items[2], items[3], items[0], items[4], items[5]], movies: items.filter { $0.kind == .movie }, series: items.filter { $0.kind == .series }, views: [
            MediaItem(id: "demo-library-movies", title: L10n.service("demo.library.movies"), kind: .collection),
            MediaItem(id: "demo-library-series", title: L10n.service("demo.library.series"), kind: .collection)
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
        let titles = id == "demo-tokyo" ? [L10n.service("demo.tokyo.episode.1"), L10n.service("demo.tokyo.episode.2"), L10n.service("demo.tokyo.episode.3"), L10n.service("demo.tokyo.episode.4"), L10n.service("demo.tokyo.episode.5"), L10n.service("demo.tokyo.episode.6"), L10n.service("demo.tokyo.episode.7"), L10n.service("demo.tokyo.episode.8")] : [L10n.service("demo.forest.episode.1"), L10n.service("demo.forest.episode.2"), L10n.service("demo.forest.episode.3"), L10n.service("demo.forest.episode.4"), L10n.service("demo.forest.episode.5"), L10n.service("demo.forest.episode.6")]
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
        throw ServiceError(code: "NOT_FOUND", message: L10n.service("demo.notFound"))
    }

    mutating func favorite(id: String, value: Bool) throws {
        _ = try item(id: id)
        if value { favorites.insert(id) } else { favorites.remove(id) }
        defaults.set(Array(favorites).sorted(), forKey: Self.favoritesKey)
    }

    func playback(id: String) throws -> PlaybackInfo {
        _ = try item(id: id)
        return PlaybackInfo(isDemo: true, label: L10n.service("demo.playback"), url: URL(string: "https://media.w3.org/2010/05/sintel/trailer.mp4")!, itemID: id, mediaSourceID: "demo-sintel-trailer", playSessionID: "demo", playMethod: "DirectPlay", mimeType: "video/mp4", startTicks: 0, subtitles: [], audioTracks: [])
    }
}
