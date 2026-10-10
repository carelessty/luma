import Foundation

enum MediaKind: String, Codable, Sendable {
    case movie, series, episode, collection, other
}

struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var originalTitle: String? = nil
    var kind: MediaKind = .movie
    var overview: String = ""
    var year: Int? = nil
    var durationTicks: Int64 = 0
    var rating: Double? = nil
    var genres: [String] = []
    var imageURL: URL? = nil
    var backdropURL: URL? = nil
    var positionTicks: Int64 = 0
    var isFavorite: Bool = false
    var isPlayed: Bool = false
    var tagline: String? = nil
    var seriesID: String? = nil
    var seriesTitle: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    var childCount: Int? = nil

    var durationMinutes: Int { Int(max(0, durationTicks) / 600_000_000) }
    var progress: Double {
        guard durationTicks > 0 else { return 0 }
        return min(100, max(0, Double(positionTicks) / Double(durationTicks) * 100))
    }
    var durationLabel: String {
        let minutes = durationMinutes
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return minutes > 0 ? "\(minutes) 分钟" : ""
    }
}

struct Session: Equatable, Sendable {
    var serverURL: String
    var userID: String
    var userName: String
    var serverName: String
    var deviceID: String
}

struct HomeData: Sendable {
    var featured: MediaItem?
    var resume: [MediaItem] = []
    var latest: [MediaItem] = []
    var movies: [MediaItem] = []
    var series: [MediaItem] = []
    var views: [MediaItem] = []
    var notice: String? = nil
}

struct LibraryQuery: Sendable {
    var kind: String? = nil
    var parentID: String? = nil
    var search: String? = nil
    var favorites: Bool? = nil
    var startIndex: Int? = nil
    var limit: Int? = nil
    var sortBy: String? = nil
    var sortOrder: String? = nil
}

struct LibraryPage: Sendable {
    var items: [MediaItem]
    var total: Int
}

struct SubtitleTrack: Sendable {
    var index: Int
    var title: String
    var url: URL
    var language: String?
    var isDefault: Bool
}

struct AudioTrack: Sendable {
    var index: Int
    var title: String
    var language: String?
}

struct PlaybackInfo: Sendable {
    var isDemo: Bool = false
    var label: String? = nil
    var url: URL
    var itemID: String
    var mediaSourceID: String
    var playSessionID: String
    var playMethod: String
    var mimeType: String
    var startTicks: Int64
    var subtitles: [SubtitleTrack]
    var audioTracks: [AudioTrack]
    var requiresLocalConversion: Bool = false
    var localVideoCodec: String? = nil
    var usesMPV: Bool = false
}

struct PlaybackEvent: Sendable {
    var type: String
    var itemID: String
    var mediaSourceID: String
    var playSessionID: String
    var playMethod: String
    var positionTicks: Int64
    var isPaused: Bool? = nil
    var isMuted: Bool? = nil
    var volumeLevel: Int? = nil
}

struct Preferences: Codable, Equatable, Sendable {
    var maxBitrateMbps: Int = 40
    var autoplayNext: Bool = true
    var defaultSubtitle: Bool = false
    var reducedMotion: Bool = false

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: "luma.native.preferences.v1"),
              var value = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        value.maxBitrateMbps = min(200, max(1, value.maxBitrateMbps))
        return value
    }

    func save() {
        var value = self
        value.maxBitrateMbps = min(200, max(1, maxBitrateMbps))
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "luma.native.preferences.v1")
        }
    }
}

struct ServiceError: LocalizedError, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}
