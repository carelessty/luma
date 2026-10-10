import Foundation
import Testing
@testable import Luma

/// Test sessions never read or modify the user's real login Keychain.
private final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredSession?
    private var writeFailure = false
    private(set) var reads = 0

    func load() throws -> StoredSession? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return value
    }
    func save(_ value: StoredSession) throws {
        lock.lock(); defer { lock.unlock() }
        if writeFailure { throw ServiceError(code: "SESSION_STORAGE", message: "Fixture storage failure") }
        self.value = value
    }
    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        if writeFailure { throw ServiceError(code: "SESSION_STORAGE", message: "Fixture storage failure") }
        value = nil
    }
    func setWriteFailure(_ fail: Bool) {
        lock.lock(); defer { lock.unlock() }
        writeFailure = fail
    }
}

private final class EmbyMockProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Any?))?
    static var responseDelay: (URLRequest) -> TimeInterval = { _ in 0 }
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        let delay = Self.responseDelay(request)
        Self.lock.unlock()
        do {
            let (status, body) = try handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let deliver = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data { client?.urlProtocol(self, didLoad: data) }
                client?.urlProtocolDidFinishLoading(self)
            }
            if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver) }
            else { deliver() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func install(_ callback: @escaping (URLRequest) throws -> (Int, Any?), delay: @escaping (URLRequest) -> TimeInterval = { _ in 0 }) {
        lock.lock(); defer { lock.unlock() }
        handler = callback
        responseDelay = delay
        requests = []
    }
    static func recorded() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

@Suite(.serialized)
final class BackendTests {
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private let token = "test-secret-token"

    init() {
        defaultsName = "LumaTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
    }
    deinit { defaults.removePersistentDomain(forName: defaultsName) }

    private func service(store: MemorySessionStore = MemorySessionStore(), delay: @escaping (URLRequest) -> TimeInterval = { _ in 0 }, _ handler: @escaping (URLRequest) throws -> (Int, Any?)) -> MediaService {
        EmbyMockProtocol.install(handler, delay: delay)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbyMockProtocol.self]
        return MediaService(urlSession: URLSession(configuration: config), defaults: defaults, sessionStore: store)
    }

    private func authentication(_ request: URLRequest) -> (Int, Any?)? {
        if request.url!.path.hasSuffix("AuthenticateByName") {
            return (200, ["AccessToken": token, "User": ["Id": "user1", "Name": "影迷"]])
        }
        if request.url!.path.hasSuffix("System/Info/Public") { return (200, ["ServerName": "客厅影院"]) }
        return nil
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func testAuthenticationRequestPreservesPasswordAndKeepsCredentialsOutOfURL() async throws {
        let password = " \tfixture/密碼+\"\\word\n "
        let client = service { [self] request in
            if request.url!.path.hasSuffix("AuthenticateByName") {
                #expect(request.httpMethod == "POST")
                #expect(request.url!.path == "/proxy/emby/Users/AuthenticateByName")
                #expect(request.url!.query == nil)
                #expect(request.url!.user == nil)
                #expect(request.url!.password == nil)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                let authorization = try #require(request.value(forHTTPHeaderField: "X-Emby-Authorization"))
                #expect(authorization.hasPrefix("Emby "))
                #expect(authorization.contains("Client=\"Luma\""))
                #expect(authorization.contains("DeviceId=\""))
                #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
                #expect(!authorization.contains(password))
                let body = try jsonBody(request)
                #expect(body["Username"] as? String == "viewer")
                #expect(body["Pw"] as? String == password)
                #expect(Set(body.keys) == ["Username", "Pw"])
            }
            return authentication(request) ?? (404, nil)
        }
        _ = try await client.connect(serverURL: "https://media.example/proxy/emby", username: " viewer ", password: password)
        #expect(EmbyMockProtocol.recorded().filter { $0.url!.path.hasSuffix("AuthenticateByName") }.count == 1)
    }

    @Test
    func testEmptyPasswordBadRequestIsAuthenticationFailure() async throws {
        let client = service { [self] request in
            #expect(request.url!.path.hasSuffix("AuthenticateByName"))
            let body = try jsonBody(request)
            #expect(body["Pw"] as? String == "")
            return (400, ["error": "invalid request"])
        }
        do {
            _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "")
            Issue.record("Rejected empty password must not authenticate")
        } catch let error as ServiceError {
            #expect(error.code == "AUTH_FAILED")
            #expect(error.message.contains("空密码"))
        }
        #expect(try await client.session() == nil)
        #expect(EmbyMockProtocol.recorded().count == 1)
    }

    @Test
    func testNonemptyPasswordBadRequestIsAuthenticationFailure() async throws {
        let password = "fixture-rejected-password"
        let client = service { [self] request in
            #expect(request.url!.path.hasSuffix("AuthenticateByName"))
            let body = try jsonBody(request)
            #expect(body["Pw"] as? String == password)
            return (400, ["error": "invalid request"])
        }
        do {
            _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: password)
            Issue.record("Rejected password must not authenticate")
        } catch let error as ServiceError {
            #expect(error.code == "AUTH_FAILED")
            #expect(!error.message.contains(password))
        }
        #expect(try await client.session() == nil)
        #expect(EmbyMockProtocol.recorded().count == 1)
    }

    @Test
    func testLibraryBadRequestDoesNotBecomeAuthenticationFailure() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            #expect(request.url!.path == "/emby/Users/user1/Items")
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == token)
            return (400, ["error": "invalid request"])
        }
        let session = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "fixture-password")
        do {
            _ = try await client.library()
            Issue.record("Invalid library request must fail")
        } catch let error as ServiceError {
            #expect(error.code == "BAD_REQUEST")
        }
        #expect(try await client.session()?.userID == session.userID)
    }

    @Test
    func testServerNormalizationPreservesProxyAndRejectsUnsafeAddresses() throws {
        #expect(try MediaService.normalizeServer("localhost:8096").absoluteString == "http://localhost:8096/emby/")
        #expect(try MediaService.normalizeServer(" https://media.example/proxy/emby ").absoluteString == "https://media.example/proxy/emby/")
        for invalid in ["", "ftp://example.com", "https://user:pass@example.com", "https://example.com/web/index.html", "https://example.com/?api_key=secret", "https://example.com/#home"] {
            #expect(throws: (any Error).self) { try MediaService.normalizeServer(invalid) }
        }
    }

    @Test
    func testMediaURLsRetainProxyPathAndNeverExportCredential() throws {
        let base = try MediaService.normalizeServer("https://media.example/proxy/emby")
        for path in ["Videos/1/master.m3u8", "/emby/Videos/1/master.m3u8", "/proxy/emby/Videos/1/master.m3u8"] {
            let result = try MediaService.mediaURL(base: base, path: path, token: token)
            #expect(result.path == "/proxy/emby/Videos/1/master.m3u8")
            #expect(URLComponents(url: result, resolvingAgainstBaseURL: true)?.queryItems?.first?.value == token)
        }
        for path in ["https://other.example/stream.mp4", "http://media.example/stream.mp4", "//other.example/stream.mp4", "https://user:password@media.example/stream.mp4"] {
            #expect(throws: (any Error).self) { try MediaService.mediaURL(base: base, path: path, token: token) }
        }
        let replaced = try MediaService.mediaURL(base: base, path: "Videos/1/stream.mp4?API_KEY=stale", token: token)
        #expect(URLComponents(url: replaced, resolvingAgainstBaseURL: true)?.queryItems?.filter { $0.name.lowercased() == "api_key" }.map(\.value) == [token])
    }

    @Test
    func testDemoSearchPaginationFavoritesAndEpisodes() async throws {
        let client = service { _ in Issue.record("Demo mode must not make API requests"); return (500, nil) }
        let home = try await client.home()
        #expect(home.movies.count == 4)
        #expect(home.series.count == 2)
        #expect(home.resume.count == 3)
        let found = try await client.library(query: LibraryQuery(search: "2025 科幻"))
        #expect(found.items.map(\.id) == ["demo-voyage"])
        let page = try await client.library(query: LibraryQuery(startIndex: 1, limit: 2))
        #expect(page.total == 6)
        #expect(page.items.count == 2)
        try await client.favorite(id: "demo-voyage", value: true)
        let item = try await client.item(id: "demo-voyage")
        #expect(item.isFavorite)
        let episodes = try await client.episodes(id: "demo-tokyo")
        #expect(episodes.count == 8)
        #expect(episodes.last?.episodeNumber == 8)
        let playback = try await client.playback(id: episodes[0].id)
        #expect(playback.isDemo)
        #expect(playback.startTicks == 0)
    }

    @Test
    func testAuthenticationLibraryQueriesAndDashboardNormalization() async throws {
        let raw: [String: Any] = ["Id": "movie1", "Name": "Arrival", "Type": "Movie", "ProductionYear": 2016, "RunTimeTicks": 600_000_000, "Genres": ["Sci-Fi"], "ImageTags": ["Primary": "poster-tag"], "BackdropImageTags": ["backdrop-tag"], "UserData": ["PlaybackPositionTicks": 300_000_000, "IsFavorite": true]]
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == token)
            if request.url!.path.hasSuffix("/Latest") { return (200, [raw]) }
            return (200, ["Items": [raw], "TotalRecordCount": 91])
        }
        let session = try await client.connect(serverURL: "http://localhost:8096", username: "viewer", password: "password")
        #expect(session.serverName == "客厅影院")
        #expect(session.userName == "影迷")
        let result = try await client.library(query: LibraryQuery(kind: "movie", search: "Arrival", favorites: true, startIndex: 60, limit: 30, sortBy: "ProductionYear", sortOrder: "Descending"))
        #expect(result.total == 91)
        #expect(result.items.first?.progress == 50)
        #expect(result.items.first!.isFavorite)
        #expect(result.items.first?.imageURL?.path == "/emby/Items/movie1/Images/Primary")
        let queryRequest = EmbyMockProtocol.recorded().last!
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: queryRequest.url!, resolvingAgainstBaseURL: true)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(query["StartIndex"] == "60")
        #expect(query["Limit"] == "30")
        #expect(query["SearchTerm"] == "Arrival")
        #expect(query["Filters"] == "IsFavorite")
        #expect(query["IncludeItemTypes"] == "Movie")
        let home = try await client.home()
        #expect(home.latest.count == 1)
        #expect(home.featured?.id == "movie1")
        #expect(home.views.count == 1)
        #expect(!(defaults.dictionaryRepresentation().values.contains { "\($0)".contains(token) }))
    }

    @Test
    func testHomeRetainsAvailableSectionsWhenResumeEndpointFails() async throws {
        let raw: [String: Any] = ["Id": "movie1", "Name": "Arrival", "Type": "Movie"]
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            if request.url!.path.hasSuffix("/Resume") { return (503, nil) }
            if request.url!.path.hasSuffix("/Latest") { return (200, [raw]) }
            return (200, ["Items": [raw], "TotalRecordCount": 1])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let home = try await client.home()
        #expect(home.resume.isEmpty)
        #expect(home.latest.map(\.id) == ["movie1"])
        #expect(home.movies.map(\.id) == ["movie1"])
        #expect(home.views.map(\.id) == ["movie1"])
        #expect(home.notice?.contains("继续观看") == true)
    }

    @Test
    func testHomeStillReportsServerFailureWhenEverySectionFails() async throws {
        let client = service { [self] request in authentication(request) ?? (503, nil) }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        do { _ = try await client.home(); Issue.record("A completely unavailable server must not appear as an empty library") }
        catch let error as ServiceError { #expect(error.code == "SERVER") }
    }

    @Test
    func testHomeNeverMasksAnExpiredSessionWithPartialResults() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            if request.url!.path.hasSuffix("/Resume") { return (401, nil) }
            if request.url!.path.hasSuffix("/Latest") { return (200, []) }
            return (200, ["Items": [], "TotalRecordCount": 0])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        do { _ = try await client.home(); Issue.record("Authentication errors must still require reconnection") }
        catch let error as ServiceError { #expect(error.code == "AUTH_REQUIRED") }
        #expect(try await client.session() == nil)
    }

    @Test
    func testNativePlaybackAndProgressLifecycle() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            if request.url!.path.hasSuffix("PlaybackInfo") {
                return (200, ["PlaySessionId": "play1", "MediaSources": [["Id": "source1", "Container": "mp4", "SupportsDirectPlay": true, "MediaStreams": [["Index": 0, "Type": "Video", "Codec": "hevc"], ["Index": 1, "Type": "Audio", "Codec": "aac", "DisplayTitle": "中文"], ["Index": 2, "Type": "Subtitle", "IsTextSubtitleStream": true, "Language": "zho", "IsDefault": true]]]]])
            }
            return (204, nil)
        }
        _ = try await client.connect(serverURL: "https://media.example/proxy/emby", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1", maxBitrate: 20_000_000, startTicks: 12_000_000)
        #expect(playback.playMethod == "DirectPlay")
        #expect(!playback.usesMPV)
        #expect(!playback.requiresLocalConversion)
        #expect(playback.startTicks == 12_000_000)
        #expect(playback.audioTracks.count == 1)
        #expect(playback.subtitles.first?.url.path == "/proxy/emby/Videos/movie1/source1/Subtitles/2/Stream.vtt")
        #expect(playback.url.path == "/proxy/emby/Videos/movie1/stream.mp4")
        for event in ["start", "progress", "stop"] {
            try await client.report(event: PlaybackEvent(type: event, itemID: "movie1", mediaSourceID: "source1", playSessionID: "play1", playMethod: "DirectPlay", positionTicks: 99_000_000))
        }
        try await client.cancelPlayback(playSessionID: "play1")
        let paths = EmbyMockProtocol.recorded().map { $0.url!.path }
        #expect(paths.contains("/proxy/emby/Sessions/Playing"))
        #expect(paths.contains("/proxy/emby/Sessions/Playing/Progress"))
        #expect(paths.contains("/proxy/emby/Sessions/Playing/Stopped"))
        #expect(EmbyMockProtocol.recorded().last?.httpMethod == "DELETE")
    }

    @Test
    func testIncompatibleSourceUsesHLSTranscoding() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (200, ["PlaySessionId": "play1", "MediaSources": [["Id": "source1", "Container": "mkv", "SupportsDirectPlay": true, "TranscodingUrl": "/emby/Videos/movie1/master.m3u8?VideoCodec=h264", "MediaStreams": [["Type": "Video", "Codec": "unknown-future-codec"]]]]])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1")
        #expect(playback.playMethod == "Transcode")
        #expect(playback.mimeType == "application/vnd.apple.mpegurl")
        #expect(playback.url.path == "/emby/Videos/movie1/master.m3u8")
        #expect(!playback.usesMPV)
        #expect(!playback.requiresLocalConversion)
    }

    @Test
    func testMKVWithDTSUsesMPVOriginalStreamBeforeServerTranscoding() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (200, ["PlaySessionId": "play1", "MediaSources": [["Id": "source1", "Container": "mkv", "SupportsDirectPlay": true, "SupportsDirectStream": true, "SupportsTranscoding": true, "DirectStreamUrl": "/emby/Videos/movie1/stream.mkv?Static=false&MediaSourceId=old&DeviceId=old&PlaySessionId=old&api_key=old", "TranscodingUrl": "/emby/Videos/movie1/master.m3u8?VideoCodec=h264", "MediaStreams": [["Index": 0, "Type": "Video", "Codec": "hevc"], ["Index": 1, "Type": "Audio", "Codec": "dts", "Channels": 8], ["Index": 2, "Type": "Audio", "Codec": "truehd", "Channels": 8]]]]])
        }
        _ = try await client.connect(serverURL: "https://media.example/proxy/emby", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1", startTicks: 120_000_000)
        #expect(playback.usesMPV)
        #expect(!playback.requiresLocalConversion)
        #expect(playback.localVideoCodec == nil)
        #expect(playback.playMethod == "DirectPlay")
        #expect(playback.audioTracks.count == 2)
        #expect(playback.mimeType == "video/x-matroska")
        #expect(playback.startTicks == 120_000_000)
        #expect(playback.url.path == "/proxy/emby/Videos/movie1/stream.mkv")
        let query = try #require(URLComponents(url: playback.url, resolvingAgainstBaseURL: true)?.queryItems)
        for name in ["Static", "MediaSourceId", "DeviceId", "PlaySessionId", "api_key"] {
            #expect(query.filter { $0.name.lowercased() == name.lowercased() }.count == 1)
        }
        #expect(query.first { $0.name == "Static" }?.value == "true")
        #expect(query.first { $0.name == "MediaSourceId" }?.value == "source1")
        #expect(query.first { $0.name == "api_key" }?.value == token)
        let request = try #require(EmbyMockProtocol.recorded().first { $0.url!.path.hasSuffix("PlaybackInfo") })
        let body = try jsonBody(request)
        #expect(body["MaxAudioChannels"] == nil)
        #expect(body["DirectPlayProtocols"] as? [String] == ["Http"])
        let profile = try #require(body["DeviceProfile"] as? [String: Any])
        let direct = try #require((profile["DirectPlayProfiles"] as? [[String: String]])?.first)
        #expect(direct["Container"]?.split(separator: ",").contains("mkv") == true)
        #expect(direct["AudioCodec"]?.split(separator: ",").contains("dts") == true)
        #expect(direct["AudioCodec"]?.split(separator: ",").contains("truehd") == true)
        let subtitles = try #require(profile["SubtitleProfiles"] as? [[String: String]])
        #expect(subtitles.contains { $0["Format"] == "ass" && $0["Method"] == "Embed" })
        #expect(subtitles.contains { $0["Format"] == "pgssub" && $0["Method"] == "Embed" })
    }

    @Test(arguments: ["hevc", "av1", "vp9"])
    func testMPVConstructsOriginalEndpointWhenServerOnlyProvidesFilesystemPath(codec: String) async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (200, ["PlaySessionId": "play1", "MediaSources": [["Id": "source1", "Container": "mkv", "SupportsDirectPlay": true, "SupportsTranscoding": false, "Path": "/mnt/media/private/movie.mkv", "MediaStreams": [["Type": "Video", "Codec": codec], ["Type": "Audio", "Codec": "flac"]]]]])
        }
        _ = try await client.connect(serverURL: "https://media.example/proxy/emby", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1")
        #expect(playback.usesMPV)
        #expect(!playback.requiresLocalConversion)
        #expect(playback.playMethod == "DirectPlay")
        #expect(playback.url.path == "/proxy/emby/Videos/movie1/stream.mkv")
        #expect(!playback.url.absoluteString.contains("mnt"))
    }

    @Test(arguments: ["mp4", "mkv", "hls"])
    func testDirectStreamOnlySourcePreservesRemuxSemantics(container: String) async throws {
        let extensionName = container == "hls" ? "m3u8" : container
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (200, ["PlaySessionId": "play1", "MediaSources": [["Id": "source1", "Container": container, "SupportsDirectPlay": false, "SupportsDirectStream": true, "DirectStreamUrl": "Videos/movie1/stream.\(extensionName)?Static=false&VideoCodec=copy&AudioCodec=copy", "MediaStreams": [["Type": "Video", "Codec": "hevc"], ["Type": "Audio", "Codec": "aac"]]]]])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1")
        #expect(playback.usesMPV == (container == "mkv"))
        #expect(playback.playMethod == "DirectStream")
        let query = try #require(URLComponents(url: playback.url, resolvingAgainstBaseURL: true)?.queryItems)
        #expect(query.filter { $0.name.lowercased() == "static" }.map(\.value) == ["false"])
        #expect(query.first { $0.name == "VideoCodec" }?.value == "copy")
        #expect(query.first { $0.name == "AudioCodec" }?.value == "copy")
    }

    @Test
    func testNativeSourceWinsAcrossMultipleVersionsBeforeMPVAndTranscoding() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            let streams = [["Type": "Video", "Codec": "hevc"], ["Type": "Audio", "Codec": "aac"]]
            return (200, ["PlaySessionId": "play1", "MediaSources": [
                ["Id": "fallback", "TranscodingUrl": "Videos/movie1/master.m3u8"],
                ["Id": "original", "Container": "mkv", "SupportsDirectPlay": true, "MediaStreams": streams],
                ["Id": "native", "Container": "mov", "SupportsDirectPlay": true, "MediaStreams": streams]
            ]])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1")
        #expect(!playback.usesMPV)
        #expect(playback.mediaSourceID == "native")
        #expect(playback.url.path == "/emby/Videos/movie1/stream.mov")
    }

    @Test
    func testMPVSourceWinsAcrossMultipleVersionsBeforeTranscoding() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (200, ["PlaySessionId": "play1", "MediaSources": [
                ["Id": "fallback", "TranscodingUrl": "Videos/movie1/master.m3u8"],
                ["Id": "original", "Container": "webm", "SupportsDirectPlay": true, "MediaStreams": [["Type": "Video", "Codec": "vp9"], ["Type": "Audio", "Codec": "opus"]]]
            ]])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1")
        #expect(playback.usesMPV)
        #expect(playback.mediaSourceID == "original")
        #expect(playback.playMethod == "DirectPlay")
        #expect(playback.url.path == "/emby/Videos/movie1/stream.webm")
    }

    @Test
    func testMP4WithDTSUsesMPVToPreserveAllOriginalAudioTracks() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (200, ["PlaySessionId": "play1", "MediaSources": [["Id": "source1", "Container": "mp4", "SupportsDirectPlay": true, "MediaStreams": [
                ["Index": 0, "Type": "Video", "Codec": "hevc"],
                ["Index": 1, "Type": "Audio", "Codec": "aac"],
                ["Index": 2, "Type": "Audio", "Codec": "dts"]
            ]]]])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1")
        #expect(playback.usesMPV)
        #expect(playback.mimeType == "video/mp4")
        #expect(playback.audioTracks.map(\.index) == [1, 2])
        #expect(playback.url.path == "/emby/Videos/movie1/stream.mp4")
    }

    @Test
    func testMPVLeavesEmbeddedSubtitlesToItsOwnTracksAndExposesOnlyExternalVTT() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (200, ["PlaySessionId": "play1", "MediaSources": [["Id": "source1", "Container": "mkv", "SupportsDirectPlay": true, "MediaStreams": [
                ["Index": 0, "Type": "Video", "Codec": "hevc"],
                ["Index": 1, "Type": "Subtitle", "Codec": "ass", "IsTextSubtitleStream": true, "IsExternal": false],
                ["Index": 2, "Type": "Subtitle", "Codec": "pgssub", "IsTextSubtitleStream": false, "IsExternal": false],
                ["Index": 3, "Type": "Subtitle", "Codec": "srt", "IsTextSubtitleStream": true, "IsExternal": true, "IsDefault": true, "Language": "zho", "DisplayTitle": "简体中文"]
            ]]]])
        }
        _ = try await client.connect(serverURL: "https://media.example/proxy/emby", username: "viewer", password: "password")
        let playback = try await client.playback(id: "movie1")
        #expect(playback.usesMPV)
        #expect(playback.subtitles.map(\.index) == [3])
        #expect(playback.subtitles.first?.url.path == "/proxy/emby/Videos/movie1/source1/Subtitles/3/Stream.vtt")
        #expect(playback.subtitles.first?.isDefault == true)
        #expect(playback.subtitles.first?.title == "简体中文")
    }

    @Test
    func testPlaybackRejectsUnusableAndUnadvertisedSources() async throws {
        let sources: [[String: Any]] = [
            ["Id": "source1", "Container": "mkv", "SupportsDirectStream": true, "Path": "/mnt/movie.mkv", "MediaStreams": [["Type": "Video", "Codec": "hevc"]]],
            ["Id": "source1", "Container": "mkv", "SupportsDirectPlay": true, "MediaStreams": [["Type": "Video", "Codec": "unknown"]]],
            ["Id": "source1", "Container": "mkv", "SupportsDirectPlay": true, "MediaStreams": [["Type": "Video", "Codec": "hevc"], ["Type": "Audio", "Codec": "unknown"]]],
            ["Id": "source1", "Container": "../../secret", "SupportsDirectPlay": true, "MediaStreams": [["Type": "Video", "Codec": "hevc"]]],
            ["Id": "source1", "Container": "mkv", "SupportsDirectPlay": false, "SupportsDirectStream": false, "SupportsTranscoding": false, "TranscodingUrl": "Videos/movie1/master.m3u8", "MediaStreams": [["Type": "Video", "Codec": "hevc"]]]
        ]
        for source in sources {
            let client = service { [self] request in
                if let auth = authentication(request) { return auth }
                return (200, ["PlaySessionId": "play1", "MediaSources": [source]])
            }
            _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
            do { _ = try await client.playback(id: "movie1"); Issue.record("Invalid direct-play source must not become a guessed network URL") }
            catch let error as ServiceError { #expect(error.code == "PLAYBACK_UNSUPPORTED") }
        }
    }

    @Test
    func testMPVRejectsCrossOriginSourcesAndLegacyConversionRemainsConservative() async throws {
        let stream: [String: Any] = ["Type": "Video", "Codec": "hevc"]
        #expect(!MediaService.localConversionCandidate(["Container": "mkv", "SupportsDirectPlay": true, "MediaStreams": [stream]]))
        #expect(!MediaService.localConversionCandidate(["Container": "mkv", "SupportsDirectPlay": true, "DirectStreamUrl": "Videos/1/stream.mkv", "MediaStreams": [["Type": "Video", "Codec": "av1"]]]))
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (200, ["PlaySessionId": "play1", "MediaSources": [["Id": "source1", "Container": "mkv", "SupportsDirectPlay": true, "DirectStreamUrl": "https://other.example/video.mkv", "MediaStreams": [stream]]]])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        do { _ = try await client.playback(id: "movie1"); Issue.record("Cross-origin source must not receive the Emby credential") }
        catch let error as ServiceError { #expect(error.code == "PLAYBACK_UNSUPPORTED") }
    }

    @Test
    func testExpiredSessionDoesNotSilentlyBecomeDemo() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (401, ["message": "unauthorized"])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        do { _ = try await client.library(); Issue.record("Expected expired session") }
        catch let error as ServiceError { #expect(error.code == "AUTH_REQUIRED") }
        do { _ = try await client.home(); Issue.record("Must not show demo as real server data") }
        catch let error as ServiceError { #expect(error.code == "AUTH_REQUIRED") }
        try await client.disconnect()
        let home = try await client.home()
        #expect(home.featured?.id == "demo-voyage")
    }

    @Test
    func testCancellingConnectionDuringServerInfoDoesNotCommitSession() async throws {
        let (infoSignal, infoContinuation) = AsyncStream<Void>.makeStream()
        let (logoutSignal, logoutContinuation) = AsyncStream<Void>.makeStream()
        let client = service { [self] request in
            if request.url!.path.hasSuffix("System/Info/Public") {
                infoContinuation.yield(())
                Thread.sleep(forTimeInterval: 0.05)
                return (200, ["ServerName": "Cancelled server"])
            }
            if request.url!.path.hasSuffix("Sessions/Logout") {
                logoutContinuation.yield(())
                return (204, nil)
            }
            return authentication(request) ?? (404, nil)
        }
        let login = Task { try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password") }
        for await _ in infoSignal { login.cancel(); break }
        do { _ = try await login.value; Issue.record("Cancelled login must not succeed") }
        catch is CancellationError {}
        catch { Issue.record("Expected CancellationError") }
        let session = try await client.session()
        #expect(session == nil)
        for await _ in logoutSignal { break }
        infoContinuation.finish()
        logoutContinuation.finish()
    }

    @Test
    func testLogoutClearsLocalSessionWhenServerFails() async throws {
        let client = service { [self] request in
            if let auth = authentication(request) { return auth }
            return (503, ["error": "offline"])
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        try await client.disconnect()
        let session = try await client.session()
        #expect(session == nil)
        let home = try await client.home()
        #expect(home.featured?.id == "demo-voyage")
    }

    @Test
    func testConnectionRestoresWithoutPasswordAuthenticationAndUsesSavedDevice() async throws {
        let store = MemorySessionStore()
        let first = service(store: store) { [self] request in authentication(request) ?? (204, nil) }
        let connected = try await first.connect(serverURL: "https://media.example/proxy/emby", username: "viewer", password: "password-not-stored")
        let saved = try #require(try store.load())
        let encoded = try JSONEncoder().encode(saved)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("password-not-stored"))
        #expect(saved.token == token)
        defaults.removeObject(forKey: "luma.native.deviceID")
        let restored = service(store: store) { [self] request in
            #expect(request.url!.path == "/proxy/emby/Users/user1/Views")
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == token)
            #expect(request.value(forHTTPHeaderField: "X-Emby-Authorization")!.contains("DeviceId=\"\(connected.deviceID)\""))
            return (200, ["Items": []])
        }
        #expect(try await restored.restoreSession() == connected)
        #expect(try await restored.restoreSession() == connected)
        #expect(EmbyMockProtocol.recorded().count == 1)
        #expect(!defaults.dictionaryRepresentation().values.contains { "\($0)".contains(token) })
    }

    @Test
    func testOfflineRestoreRetainsCredentialAndCanRetryWithoutLogin() async throws {
        let store = MemorySessionStore()
        let first = service(store: store) { [self] request in authentication(request) ?? (204, nil) }
        let connected = try await first.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let restored = service(store: store) { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await restored.restoreSession(); Issue.record("Offline validation should report the network error") }
        catch let error as ServiceError { #expect(error.code == "NETWORK") }
        #expect(try await restored.session() == connected)
        #expect(try store.load()?.token == token)
        EmbyMockProtocol.install { [self] request in
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == token)
            return (200, ["Items": [], "TotalRecordCount": 0])
        }
        #expect(try await restored.library().items.isEmpty)
        #expect(EmbyMockProtocol.recorded().allSatisfy { !$0.url!.path.hasSuffix("AuthenticateByName") })
    }

    @Test
    func testExpiredRestoredTokenIsRemovedAndNeverShowsDemo() async throws {
        let store = MemorySessionStore()
        let first = service(store: store) { [self] request in authentication(request) ?? (204, nil) }
        _ = try await first.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let restored = service(store: store) { _ in (401, nil) }
        do { _ = try await restored.restoreSession(); Issue.record("Expected expired token") }
        catch let error as ServiceError { #expect(error.code == "AUTH_REQUIRED") }
        #expect(try store.load() == nil)
        #expect(try await restored.session() == nil)
        do { _ = try await restored.restoreSession(); Issue.record("Expired session must require login") }
        catch let error as ServiceError { #expect(error.code == "AUTH_REQUIRED") }
        do { _ = try await restored.home(); Issue.record("Expired session must not become demo") }
        catch let error as ServiceError { #expect(error.code == "AUTH_REQUIRED") }
    }

    @Test
    func testDelayedUnauthorizedResponseCannotEraseReconnectedSession() async throws {
        let store = MemorySessionStore()
        let (requested, continuation) = AsyncStream<Void>.makeStream()
        let client = service(store: store, delay: { $0.url!.path.hasSuffix("/Items") ? 0.25 : 0 }) { [self] request in
            if let auth = authentication(request) { return auth }
            continuation.yield(())
            return (401, nil)
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let oldRequest = Task { try await client.library() }
        for await _ in requested { break }
        let reconnected = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        do { _ = try await oldRequest.value; Issue.record("The old request should fail") }
        catch let error as ServiceError { #expect(error.code == "SESSION_CHANGED") }
        #expect(try await client.session() == reconnected)
        #expect(try store.load()?.token == token)
        continuation.finish()
    }

    @Test
    func testFailedSwitchPreservesPreviousStoredConnection() async throws {
        let store = MemorySessionStore()
        let client = service(store: store) { [self] request in
            if request.url!.host == "rejected.example" { return (401, nil) }
            return authentication(request) ?? (204, nil)
        }
        let previous = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        do { _ = try await client.connect(serverURL: "https://rejected.example", username: "viewer", password: "wrong"); Issue.record("Expected failed switch") }
        catch let error as ServiceError { #expect(error.code == "AUTH_FAILED") }
        #expect(try await client.session() == previous)
        #expect(try store.load()?.session == previous)
    }

    @Test
    func testStorageFailureDoesNotCommitNewConnection() async throws {
        let store = MemorySessionStore()
        let (logoutSignal, logoutContinuation) = AsyncStream<Void>.makeStream()
        let client = service(store: store) { [self] request in
            if request.url!.path.hasSuffix("Sessions/Logout") {
                logoutContinuation.yield(())
                return (204, nil)
            }
            return authentication(request) ?? (204, nil)
        }
        let previous = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        store.setWriteFailure(true)
        do { _ = try await client.connect(serverURL: "https://replacement.example", username: "viewer", password: "password"); Issue.record("Failed Keychain save must not succeed") }
        catch let error as ServiceError { #expect(error.code == "SESSION_STORAGE") }
        #expect(try await client.session() == previous)
        #expect(try store.load()?.session == previous)
        for await _ in logoutSignal { break }
        logoutContinuation.finish()
    }

    @Test
    func testSuccessfulSwitchReplacesStoredConnectionAndLogoutForgetsIt() async throws {
        let store = MemorySessionStore()
        let (logoutSignal, logoutContinuation) = AsyncStream<Void>.makeStream()
        let client = service(store: store) { [self] request in
            if request.url!.path.hasSuffix("Sessions/Logout") {
                logoutContinuation.yield(())
                return (503, nil)
            }
            return authentication(request) ?? (204, nil)
        }
        _ = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        let next = try await client.connect(serverURL: "https://replacement.example", username: "viewer", password: "password")
        #expect(try store.load()?.session == next)
        for await _ in logoutSignal { break }
        try await client.disconnect()
        #expect(try store.load() == nil)
        #expect(try await client.restoreSession() == nil)
        logoutContinuation.finish()
    }

    @Test
    func testRefusedKeychainRemovalDoesNotPretendToForgetConnection() async throws {
        let store = MemorySessionStore()
        let client = service(store: store) { [self] request in authentication(request) ?? (204, nil) }
        let connected = try await client.connect(serverURL: "https://media.example", username: "viewer", password: "password")
        store.setWriteFailure(true)
        do { try await client.disconnect(); Issue.record("Denied credential deletion must surface an error") }
        catch let error as ServiceError { #expect(error.code == "SESSION_STORAGE") }
        #expect(try await client.session() == connected)
        #expect(try store.load()?.session == connected)
        #expect(!EmbyMockProtocol.recorded().contains { $0.url!.path.hasSuffix("Sessions/Logout") })
    }

    @Test
    func testMissingSavedConnectionIsReadOnlyOnce() async throws {
        let store = MemorySessionStore()
        let client = service(store: store) { _ in Issue.record("Empty storage must not make requests"); return (500, nil) }
        #expect(try await client.restoreSession() == nil)
        #expect(try await client.restoreSession() == nil)
        #expect(store.reads == 1)
    }
}
