import Foundation

/// Reject API redirects so credentials cannot move to an unexpected host.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Owns the live session and persists only its access token in the Keychain.
actor MediaService {
    private struct Auth {
        var session: Session
        let base: URL
        let token: String
        let generation: Int
    }

    private let http: URLSession
    private var deviceID: String
    private let sessionStore: any SessionStore
    private var auth: Auth?
    private var generation = 0
    private var connecting = false
    private var expired = false
    private var restorationAttempted = false
    private var demo: DemoCatalog
    private let fields = "Overview,Genres,PrimaryImageAspectRatio,DateCreated,Taglines"

    init(urlSession: URLSession? = nil, defaults: UserDefaults = .standard, sessionStore: any SessionStore = KeychainSessionStore()) {
        self.sessionStore = sessionStore
        if let urlSession { http = urlSession } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 45
            config.httpMaximumConnectionsPerHost = 8
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            http = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
        let identifier = defaults.string(forKey: "luma.native.deviceID") ?? UUID().uuidString
        defaults.set(identifier, forKey: "luma.native.deviceID")
        deviceID = identifier
        demo = DemoCatalog(defaults: defaults)
    }

    func session() async throws -> Session? { auth?.session }

    /// Called once at startup before loading the library. A temporary network
    /// failure preserves the restored session so Refresh can retry it.
    func restoreSession() async throws -> Session? {
        if let auth { return auth.session }
        if expired { throw ServiceError(code: "AUTH_REQUIRED", message: "登录已过期，请重新连接服务器。") }
        if restorationAttempted { return nil }
        guard !connecting else { throw ServiceError(code: "CONNECTING", message: "正在连接服务器，请稍候。") }
        guard let saved = try sessionStore.load() else { restorationAttempted = true; return nil }
        let base = try Self.normalizeServer(saved.serverURL)
        try Self.validID(saved.userID)
        guard !saved.token.isEmpty, !saved.token.contains("\r"), !saved.token.contains("\n"),
              !saved.deviceID.isEmpty, !saved.deviceID.contains("\""), !saved.deviceID.contains("\r"), !saved.deviceID.contains("\n") else {
            throw ServiceError(code: "SESSION_STORAGE", message: "保存的连接凭据无效，请重新连接服务器。")
        }
        try Task.checkCancellation()
        generation += 1
        deviceID = saved.deviceID
        let restored = Auth(session: saved.session, base: base, token: saved.token, generation: generation)
        auth = restored
        expired = false
        restorationAttempted = true
        // Views requires authentication, unlike System/Info/Public. Do not
        // discard a valid credential just because the server is offline.
        _ = try await fetch(restored, path: "Users/\(saved.userID)/Views")
        return restored.session
    }

    static func normalizeServer(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2048,
              var parts = URLComponents(string: text.contains("://") ? text : "http://" + text),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw ServiceError(code: "INVALID_SERVER", message: "请输入 HTTP 或 HTTPS 服务器根地址，不包含账号、查询参数或页面锚点。")
        }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.lowercased().split(separator: "/").contains("web"), !path.lowercased().hasSuffix(".html") else {
            throw ServiceError(code: "INVALID_SERVER", message: "请输入服务器根地址（如 http://localhost:8096），不要包含 /web 页面路径。")
        }
        parts.path = path.isEmpty ? "/emby/" : "/\(path)/"
        guard let url = parts.url else { throw ServiceError(code: "INVALID_SERVER", message: "服务器地址格式不正确。") }
        return url
    }

    private static func validID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 256,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ServiceError(code: "INVALID_INPUT", message: "媒体标识无效。")
        }
    }

    private var authorization: String {
        "Emby Client=\"Luma\", Device=\"macOS\", DeviceId=\"\(deviceID)\", Version=\"1.0.0\""
    }

    func connect(serverURL: String, username: String, password: String) async throws -> Session {
        let base = try Self.normalizeServer(serverURL)
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServiceError(code: "INVALID_INPUT", message: "请输入用户名。") }
        guard !connecting else { throw ServiceError(code: "CONNECTING", message: "正在连接服务器，请稍候。") }
        connecting = true
        defer { connecting = false }
        generation += 1
        let requestGeneration = generation
        let data = try await request(base: base, path: "Users/AuthenticateByName", method: "POST", body: ["Username": name, "Pw": password])
        let response = try dictionary(data)
        guard let token = response["AccessToken"] as? String, !token.isEmpty,
              !token.contains("\r"), !token.contains("\n"),
              let user = response["User"] as? [String: Any], let userID = user["Id"] as? String else {
            throw ServiceError(code: "AUTH_FAILED", message: "服务器未返回有效的访问凭据或用户信息。")
        }
        try Self.validID(userID)
        var next = Auth(session: Session(serverURL: String(base.absoluteString.dropLast()), userID: userID, userName: user["Name"] as? String ?? name, serverName: base.host ?? "Emby", deviceID: deviceID), base: base, token: token, generation: requestGeneration)
        if let infoData = try? await request(base: base, path: "System/Info/Public"),
           let info = try? dictionary(infoData), let serverName = info["ServerName"] as? String {
            next.session.serverName = serverName
        }
        guard !Task.isCancelled, generation == requestGeneration else {
            if auth?.token != token || auth?.base != base {
                Task { _ = try? await self.request(base: base, path: "Sessions/Logout", method: "POST", token: token) }
            }
            if Task.isCancelled { throw CancellationError() }
            throw ServiceError(code: "SESSION_CHANGED", message: "连接请求已取消。")
        }
        do { try sessionStore.save(StoredSession(session: next.session, token: token)) }
        catch {
            // A failed save must not replace the previous working connection.
            if auth?.token != token || auth?.base != base {
                Task { _ = try? await self.request(base: base, path: "Sessions/Logout", method: "POST", token: token) }
            }
            throw error
        }
        let previous = auth
        auth = next
        expired = false
        restorationAttempted = true
        // Commit and return without suspension; cancelling the login sheet cannot
        // leave a new session committed behind a cancelled caller.
        if let previous, previous.token != token || previous.base != base {
            Task { _ = try? await self.request(base: previous.base, path: "Sessions/Logout", method: "POST", token: previous.token) }
        }
        return next.session
    }

    func disconnect() async throws {
        // Preserve the live session if removal is denied, rather than claiming
        // to forget it and silently restoring it on the next launch.
        try sessionStore.clear()
        generation += 1
        let previous = auth
        auth = nil
        expired = false
        restorationAttempted = true
        if let previous {
            _ = try? await request(base: previous.base, path: "Sessions/Logout", method: "POST", token: previous.token)
        }
    }

    private func currentAuth() throws -> Auth? {
        if expired { throw ServiceError(code: "AUTH_REQUIRED", message: "登录已过期，请重新连接服务器。") }
        return auth
    }

    private func verify(_ snapshot: Auth) throws {
        guard auth?.generation == snapshot.generation else {
            throw ServiceError(code: "SESSION_CHANGED", message: "服务器连接已变更，请刷新后重试。")
        }
    }

    private func request(base: URL, path: String, method: String = "GET", query: [String: String] = [:], body: [String: Any]? = nil, token: String? = nil, authGeneration: Int? = nil) async throws -> Data {
        guard let endpoint = URL(string: path, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else {
            throw ServiceError(code: "INVALID_INPUT", message: "请求地址无效。")
        }
        if !query.isEmpty { parts.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw ServiceError(code: "INVALID_INPUT", message: "请求地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Luma/1.0 AppKit", forHTTPHeaderField: "User-Agent")
        request.setValue(authorization, forHTTPHeaderField: "X-Emby-Authorization")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await http.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw ServiceError(code: "TIMEOUT", message: "服务器响应超时，请检查网络后重试。") }
            throw ServiceError(code: "NETWORK", message: "无法连接服务器，请检查地址、网络和 TLS 证书。")
        }
        guard let response = response as? HTTPURLResponse else { throw ServiceError(code: "INVALID_RESPONSE", message: "服务器返回了无效的响应。") }
        guard (200...299).contains(response.statusCode) else {
            switch response.statusCode {
            case 400:
                // Some Emby-compatible servers report rejected credentials as
                // 400 instead of 401. Keep that separate from media API errors.
                // Do not expose the raw response, which may echo credentials.
                if path == "Users/AuthenticateByName", method == "POST" {
                    let message = (body?["Pw"] as? String)?.isEmpty == true
                        ? "服务器拒绝了空密码登录，请填写密码后重试。"
                        : "登录请求被服务器拒绝（HTTP 400），请检查用户名和密码后重试。"
                    throw ServiceError(code: "AUTH_FAILED", message: message)
                }
                throw ServiceError(code: "BAD_REQUEST", message: "服务器无法处理此请求（HTTP 400），请刷新后重试。")
            case 401:
                // Servers may reuse an access token when the same user logs in
                // again. A late failure from the old session must not erase
                // the newly saved connection just because its token matches.
                if let authGeneration, let auth, auth.generation != authGeneration {
                    throw ServiceError(code: "SESSION_CHANGED", message: "服务器连接已变更，请刷新后重试。")
                }
                if let token, let authGeneration, auth?.generation == authGeneration, auth?.token == token, auth?.base == base {
                    auth = nil
                    expired = true
                    generation += 1
                    do { try sessionStore.clear() }
                    catch { throw ServiceError(code: "SESSION_STORAGE", message: "登录已过期，但无法删除钥匙串中的旧凭据。请允许 Luma 访问钥匙串后重新连接。") }
                }
                throw ServiceError(code: token == nil ? "AUTH_FAILED" : "AUTH_REQUIRED", message: token == nil ? "用户名或密码不正确。" : "登录已过期，请重新连接服务器。")
            case 403: throw ServiceError(code: "FORBIDDEN", message: "服务器未允许此操作，请检查账号权限。")
            case 404: throw ServiceError(code: "NOT_FOUND", message: "未找到媒体或 API，请检查服务器地址。")
            case 429: throw ServiceError(code: "RATE_LIMITED", message: "请求过于频繁，请稍后重试。")
            case 300...399: throw ServiceError(code: "INVALID_SERVER", message: "服务器要求重定向，请使用最终的服务器地址。")
            default: throw ServiceError(code: "SERVER", message: "服务器返回错误（HTTP \(response.statusCode)），请稍后重试。")
            }
        }
        return data
    }

    private func fetch(_ snapshot: Auth, path: String, method: String = "GET", query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Data {
        let result = try await request(base: snapshot.base, path: path, method: method, query: query, body: body, token: snapshot.token, authGeneration: snapshot.generation)
        try verify(snapshot)
        return result
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError(code: "INVALID_RESPONSE", message: "服务器返回了无法解析的数据。")
        }
        return object
    }

    private func items(_ data: Data, auth: Auth) throws -> [MediaItem] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let raw = object as? [[String: Any]] ?? (object as? [String: Any])?["Items"] as? [[String: Any]] else {
            throw ServiceError(code: "INVALID_RESPONSE", message: "服务器返回了无法解析的媒体列表。")
        }
        return try raw.map { try normalize($0, auth: auth) }
    }

    /// Relative URLs remain under reverse-proxy prefixes; tokens never cross origins.
    static func mediaURL(base: URL, path: String, token: String) throws -> URL {
        var result: URL?
        if path.hasPrefix("http://") || path.hasPrefix("https://") { result = URL(string: path) }
        else if !path.hasPrefix("//"), !path.contains("://") {
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.hasPrefix(basePath + "/") { result = URL(string: "/" + relative, relativeTo: base)?.absoluteURL }
            else if basePath.hasSuffix("emby"), relative.hasPrefix("emby/") { result = URL(string: String(relative.dropFirst(5)), relativeTo: base)?.absoluteURL }
            else { result = URL(string: relative, relativeTo: base)?.absoluteURL }
        }
        guard let result, var parts = URLComponents(url: result, resolvingAgainstBaseURL: true),
              result.scheme?.lowercased() == base.scheme?.lowercased(), result.host?.lowercased() == base.host?.lowercased(),
              (result.port ?? (result.scheme == "https" ? 443 : 80)) == (base.port ?? (base.scheme == "https" ? 443 : 80)),
              parts.user == nil, parts.password == nil else {
            throw ServiceError(code: "PLAYBACK_UNSUPPORTED", message: "服务器返回了无效或指向其他服务器的媒体地址。")
        }
        var query = (parts.queryItems ?? []).filter { $0.name.lowercased() != "api_key" }
        query.append(URLQueryItem(name: "api_key", value: token))
        parts.queryItems = query
        guard let url = parts.url else { throw ServiceError(code: "INVALID_RESPONSE", message: "媒体地址无效。") }
        return url
    }

    private func imageURL(_ snapshot: Auth, id: String, type: String, tag: String, width: Int) -> URL? {
        guard (try? Self.validID(id)) != nil,
              let raw = try? Self.mediaURL(base: snapshot.base, path: "Items/\(id)/Images/\(type)", token: snapshot.token),
              var parts = URLComponents(url: raw, resolvingAgainstBaseURL: true) else { return nil }
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "maxWidth", value: String(width)), URLQueryItem(name: "quality", value: "85"), URLQueryItem(name: "tag", value: tag)]
        return parts.url
    }

    private func normalize(_ raw: [String: Any], auth: Auth) throws -> MediaItem {
        guard let id = raw["Id"] as? String else { throw ServiceError(code: "INVALID_RESPONSE", message: "媒体条目缺少标识。") }
        try Self.validID(id)
        let type = raw["Type"] as? String ?? ""
        let kind: MediaKind = ["Movie": .movie, "Series": .series, "Episode": .episode, "CollectionFolder": .collection, "BoxSet": .collection][type] ?? .other
        let userData = raw["UserData"] as? [String: Any] ?? [:]
        let duration = max(0, (raw["RunTimeTicks"] as? NSNumber)?.int64Value ?? 0)
        let position = max(0, (userData["PlaybackPositionTicks"] as? NSNumber)?.int64Value ?? 0)
        var result = MediaItem(id: id, title: raw["Name"] as? String ?? "未命名", originalTitle: raw["OriginalTitle"] as? String, kind: kind, overview: raw["Overview"] as? String ?? "", year: raw["ProductionYear"] as? Int, durationTicks: duration, rating: raw["CommunityRating"] as? Double, genres: raw["Genres"] as? [String] ?? [], positionTicks: position, isFavorite: userData["IsFavorite"] as? Bool ?? false, isPlayed: userData["Played"] as? Bool ?? false, tagline: (raw["Taglines"] as? [String])?.first, seriesID: raw["SeriesId"] as? String, seriesTitle: raw["SeriesName"] as? String, seasonNumber: raw["ParentIndexNumber"] as? Int, episodeNumber: raw["IndexNumber"] as? Int, childCount: raw["ChildCount"] as? Int)
        if let tag = (raw["ImageTags"] as? [String: String])?["Primary"] { result.imageURL = imageURL(auth, id: id, type: "Primary", tag: tag, width: 600) }
        else if let seriesID = result.seriesID, let tag = raw["SeriesPrimaryImageTag"] as? String { result.imageURL = imageURL(auth, id: seriesID, type: "Primary", tag: tag, width: 600) }
        if let tag = (raw["BackdropImageTags"] as? [String])?.first { result.backdropURL = imageURL(auth, id: id, type: "Backdrop/0", tag: tag, width: 1920) }
        else if let parent = raw["ParentBackdropItemId"] as? String, let tag = (raw["ParentBackdropImageTags"] as? [String])?.first { result.backdropURL = imageURL(auth, id: parent, type: "Backdrop/0", tag: tag, width: 1920) }
        return result
    }

    private func library(_ query: LibraryQuery, auth: Auth) async throws -> LibraryPage {
        let sortBy = query.sortBy ?? "SortName"
        guard ["SortName", "DateCreated", "ProductionYear", "CommunityRating", "DatePlayed", "Random", "PremiereDate"].contains(sortBy) else { throw ServiceError(code: "INVALID_INPUT", message: "不支持的排序方式。") }
        var params = ["Recursive": "true", "Fields": fields, "EnableImages": "true", "ImageTypeLimit": "1", "EnableUserData": "true", "StartIndex": String(max(0, query.startIndex ?? 0)), "Limit": String(min(200, max(1, query.limit ?? 60))), "SortBy": sortBy, "SortOrder": query.sortOrder == "Descending" ? "Descending" : "Ascending", "IncludeItemTypes": query.kind == "movie" ? "Movie" : query.kind == "series" ? "Series" : "Movie,Series"]
        if let parent = query.parentID { try Self.validID(parent); params["ParentId"] = parent }
        if let search = query.search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty { params["SearchTerm"] = String(search.prefix(256)) }
        if query.favorites == true { params["Filters"] = "IsFavorite" }
        let data = try await fetch(auth, path: "Users/\(auth.session.userID)/Items", query: params)
        let object = try dictionary(data)
        let values = try items(data, auth: auth)
        return LibraryPage(items: values, total: object["TotalRecordCount"] as? Int ?? values.count)
    }

    func home() async throws -> HomeData {
        guard let auth = try currentAuth() else { return demo.home() }
        let params = ["Limit": "12", "Fields": fields, "MediaTypes": "Video", "EnableUserData": "true", "ImageTypeLimit": "1"]
        async let resumeResult = homeItems(auth, path: "Users/\(auth.session.userID)/Items/Resume", query: params)
        async let latestResult = homeItems(auth, path: "Users/\(auth.session.userID)/Items/Latest", query: ["Limit": "20", "Fields": fields, "IncludeItemTypes": "Movie,Episode", "EnableUserData": "true"])
        async let movieResult = homeLibrary(LibraryQuery(kind: "movie", limit: 18, sortBy: "DateCreated", sortOrder: "Descending"), auth: auth)
        async let seriesResult = homeLibrary(LibraryQuery(kind: "series", limit: 18, sortBy: "DateCreated", sortOrder: "Descending"), auth: auth)
        async let viewsResult = homeItems(auth, path: "Users/\(auth.session.userID)/Views")
        let results = await [resumeResult, latestResult, movieResult, seriesResult, viewsResult]
        try Task.checkCancellation()
        let failures = results.compactMap { result -> (any Error)? in
            if case .failure(let error) = result { return error }
            return nil
        }
        for code in ["SESSION_STORAGE", "AUTH_REQUIRED", "SESSION_CHANGED"] {
            if let error = failures.first(where: { ($0 as? ServiceError)?.code == code }) { throw error }
        }
        try verify(auth)
        if failures.count == results.count, let error = failures.first { throw error }
        let values = results.map { (try? $0.get()) ?? [] }
        let (resume, latest, movies, series, views) = (values[0], values[1], values[2], values[3], values[4])
        let sectionNames = ["继续观看", "最近添加", "电影", "剧集", "媒体库"]
        let unavailable = zip(sectionNames, results).compactMap { name, result -> String? in
            if case .failure = result { return name }
            return nil
        }
        let notice = unavailable.isEmpty ? nil : "\(unavailable.joined(separator: "、"))暂时无法加载，其他内容仍可浏览。请稍后刷新重试。"
        return HomeData(featured: (resume + latest + movies).first(where: { $0.backdropURL != nil }) ?? latest.first ?? movies.first, resume: resume, latest: latest, movies: movies, series: series, views: views, notice: notice)
    }

    private func homeItems(_ auth: Auth, path: String, query: [String: String] = [:]) async -> Result<[MediaItem], any Error> {
        do { return .success(try items(await fetch(auth, path: path, query: query), auth: auth)) }
        catch { return .failure(error) }
    }

    private func homeLibrary(_ query: LibraryQuery, auth: Auth) async -> Result<[MediaItem], any Error> {
        do { return .success(try await library(query, auth: auth).items) }
        catch { return .failure(error) }
    }

    func library(query: LibraryQuery = LibraryQuery()) async throws -> LibraryPage {
        guard let auth = try currentAuth() else { return demo.library(query: query) }
        return try await library(query, auth: auth)
    }

    func item(id: String) async throws -> MediaItem {
        guard let auth = try currentAuth() else { return try demo.item(id: id) }
        try Self.validID(id)
        return try normalize(dictionary(await fetch(auth, path: "Users/\(auth.session.userID)/Items/\(id)")), auth: auth)
    }

    func episodes(id: String) async throws -> [MediaItem] {
        guard let auth = try currentAuth() else { return demo.episodes(id: id) }
        try Self.validID(id)
        let data = try await fetch(auth, path: "Shows/\(id)/Episodes", query: ["UserId": auth.session.userID, "Fields": fields, "EnableUserData": "true"])
        return try items(data, auth: auth)
    }

    func favorite(id: String, value: Bool) async throws {
        guard let auth = try currentAuth() else { try demo.favorite(id: id, value: value); return }
        try Self.validID(id)
        _ = try await fetch(auth, path: "Users/\(auth.session.userID)/FavoriteItems/\(id)", method: value ? "POST" : "DELETE")
    }

    static func nativeDirect(_ source: [String: Any]) -> Bool {
        guard ["mp4", "m4v", "mov", "hls", "m3u8"].contains((source["Container"] as? String ?? "").lowercased()),
              let streams = source["MediaStreams"] as? [[String: Any]] else { return false }
        let videos = streams.filter { $0["Type"] as? String == "Video" }
        let audios = streams.filter { $0["Type"] as? String == "Audio" }
        return ["h264", "hevc", "h265"].contains((videos.first?["Codec"] as? String ?? "").lowercased())
            && audios.allSatisfy { ["aac", "mp3", "ac3", "eac3", "alac"].contains(($0["Codec"] as? String ?? "").lowercased()) }
    }

    // Keep advertised capabilities aligned with bundled libmpv/FFmpeg. Unknown
    // codecs still use the server's H.264/AAC fallback instead of a blind open.
    private static let mpvContainers = ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "mpegts", "m2ts", "mpeg", "mpg", "flv", "wmv", "asf", "ogv"]
    private static let mpvVideoCodecs = ["h264", "hevc", "h265", "av1", "vp8", "vp9", "mpeg1video", "mpeg2video", "mpeg4", "vc1", "wmv3", "theora"]
    private static let mpvAudioCodecs = ["aac", "mp3", "mp2", "ac3", "eac3", "alac", "dts", "dca", "truehd", "flac", "opus", "vorbis", "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_s16be", "pcm_s24be", "wmav2", "wmapro"]

    static func mpvDirect(_ source: [String: Any]) -> Bool {
        guard mpvContainers.contains((source["Container"] as? String ?? "").lowercased()),
              let streams = source["MediaStreams"] as? [[String: Any]],
              let video = streams.first(where: { $0["Type"] as? String == "Video" }),
              mpvVideoCodecs.contains((video["Codec"] as? String ?? "").lowercased()) else { return false }
        return streams.filter { $0["Type"] as? String == "Audio" }.allSatisfy {
            mpvAudioCodecs.contains(($0["Codec"] as? String ?? "").lowercased())
        }
    }

    private struct PlaybackRoute {
        let source: [String: Any]
        let path: String
        let method: String
        let usesMPV: Bool
        let mime: String
    }

    private static func directRoute(_ source: [String: Any], itemID: String) -> PlaybackRoute? {
        let native = nativeDirect(source)
        guard native || mpvDirect(source) else { return nil }
        let container = (source["Container"] as? String ?? "").lowercased()
        let suppliedURL = (source["DirectStreamUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let canDirectPlay = source["SupportsDirectPlay"] as? Bool == true
        let path: String
        let method: String
        if canDirectPlay {
            // Emby may omit DirectStreamUrl for a source it can serve verbatim.
            // Never interpret its Path (a server filesystem path) as a URL.
            let extensionName = container == "mpegts" ? "ts" : container
            guard let direct = suppliedURL ?? (mpvContainers.contains(container) ? "Videos/\(itemID)/stream.\(extensionName)" : nil) else { return nil }
            path = direct
            method = "DirectPlay"
        } else if source["SupportsDirectStream"] as? Bool == true, let suppliedURL {
            path = suppliedURL
            method = "DirectStream"
        } else { return nil }
        let mime: String
        switch container {
        case "mkv": mime = "video/x-matroska"
        case "webm": mime = "video/webm"
        case "mp4", "m4v": mime = "video/mp4"
        case "mov": mime = "video/quicktime"
        case "hls", "m3u8": mime = "application/vnd.apple.mpegurl"
        case "ts", "mpegts", "m2ts": mime = "video/mp2t"
        default: mime = native ? "video/mp4" : "application/octet-stream"
        }
        return PlaybackRoute(source: source, path: path, method: method, usesMPV: !native, mime: mime)
    }

    /// The local bridge copies supported video and converts the audio to AAC.
    /// An explicit stream URL is required; a server-side filesystem path is not
    /// a usable network source.
    static func localConversionCandidate(_ source: [String: Any]) -> Bool {
        guard ["mkv", "mp4", "m4v", "mov"].contains((source["Container"] as? String ?? "").lowercased()),
              source["SupportsDirectPlay"] as? Bool == true || source["SupportsDirectStream"] as? Bool == true,
              let url = source["DirectStreamUrl"] as? String, !url.isEmpty,
              let streams = source["MediaStreams"] as? [[String: Any]] else { return false }
        let video = streams.first { $0["Type"] as? String == "Video" }
        return ["h264", "hevc", "h265"].contains((video?["Codec"] as? String ?? "").lowercased())
    }

    func playback(id: String, maxBitrate: Int? = nil, startTicks: Int64 = 0) async throws -> PlaybackInfo {
        guard let auth = try currentAuth() else { return try demo.playback(id: id) }
        try Self.validID(id)
        let bitrate = min(200_000_000, max(500_000, maxBitrate ?? Preferences.load().maxBitrateMbps * 1_000_000))
        let profile: [String: Any] = [
            "Name": "Luma macOS AVPlayer + libmpv", "MaxStreamingBitrate": bitrate,
            "DirectPlayProfiles": [["Container": Self.mpvContainers.joined(separator: ","), "Type": "Video", "VideoCodec": Self.mpvVideoCodecs.joined(separator: ","), "AudioCodec": Self.mpvAudioCodecs.joined(separator: ",")], ["Container": "hls,m3u8", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,mp3,ac3,eac3,alac"]],
            "TranscodingProfiles": [["Container": "ts", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac", "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "2", "MinSegments": 1, "SegmentLength": 4, "BreakOnNonKeyFrames": true]],
            "SubtitleProfiles": [["Format": "vtt", "Method": "External"]] + ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "pgs", "pgssub", "dvdsub"].map { ["Format": $0, "Method": "Embed"] }
        ]
        let body: [String: Any] = ["UserId": auth.session.userID, "MaxStreamingBitrate": bitrate, "StartTimeTicks": 0, "IsPlayback": true, "AutoOpenLiveStream": false, "EnableDirectPlay": true, "EnableDirectStream": true, "EnableTranscoding": true, "DirectPlayProtocols": ["Http"], "DeviceProfile": profile]
        let data = try dictionary(await fetch(auth, path: "Items/\(id)/PlaybackInfo", method: "POST", body: body))
        if let errorCode = data["ErrorCode"] as? String, !errorCode.isEmpty { throw ServiceError(code: "PLAYBACK_UNSUPPORTED", message: "此媒体无法播放，请检查播放和转码权限。") }
        let sources = data["MediaSources"] as? [[String: Any]] ?? []
        let directRoutes = sources.compactMap { Self.directRoute($0, itemID: id) }
        let transcoded = sources.compactMap { source -> PlaybackRoute? in
            guard let path = source["TranscodingUrl"] as? String, !path.isEmpty,
                  source["SupportsTranscoding"] as? Bool != false else { return nil }
            return PlaybackRoute(source: source, path: path, method: "Transcode", usesMPV: false, mime: "application/vnd.apple.mpegurl")
        }
        // Prefer native decoding when possible, then libmpv original streams.
        // Server transcoding is only a fallback, even if it is listed first.
        guard let route = directRoutes.first(where: { !$0.usesMPV }) ?? directRoutes.first ?? transcoded.first,
              let sourceID = route.source["Id"] as? String else {
            throw ServiceError(code: "PLAYBACK_UNSUPPORTED", message: "服务器没有提供兼容的播放地址。请检查媒体格式、播放权限或服务器转码设置。")
        }
        try Self.validID(sourceID)
        let source = route.source
        let sessionID = data["PlaySessionId"] as? String ?? ""
        var url = try Self.mediaURL(base: auth.base, path: route.path, token: auth.token)
        if route.method != "Transcode", var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            let replaced = Set(["static", "mediasourceid", "deviceid", "playsessionid"])
            // A DirectStream-only route may need server remuxing. Static=true
            // is valid only for an original DirectPlay source.
            parts.queryItems = (parts.queryItems ?? []).filter { !replaced.contains($0.name.lowercased()) } + [URLQueryItem(name: "Static", value: route.method == "DirectPlay" ? "true" : "false"), URLQueryItem(name: "MediaSourceId", value: sourceID), URLQueryItem(name: "DeviceId", value: deviceID), URLQueryItem(name: "PlaySessionId", value: sessionID)]
            url = parts.url ?? url
        }
        var subtitles: [SubtitleTrack] = []
        var audio: [AudioTrack] = []
        for stream in source["MediaStreams"] as? [[String: Any]] ?? [] {
            guard let index = stream["Index"] as? Int else { continue }
            let title = stream["DisplayTitle"] as? String ?? stream["Title"] as? String ?? stream["Language"] as? String ?? "轨道 \(index + 1)"
            let language = stream["Language"] as? String
            if stream["Type"] as? String == "Audio" { audio.append(AudioTrack(index: index, title: title, language: language)) }
            if stream["Type"] as? String == "Subtitle", stream["IsTextSubtitleStream"] as? Bool == true,
               !route.usesMPV || stream["IsExternal"] as? Bool == true {
                let subtitleURL = try Self.mediaURL(base: auth.base, path: "Videos/\(id)/\(sourceID)/Subtitles/\(index)/Stream.vtt", token: auth.token)
                subtitles.append(SubtitleTrack(index: index, title: title, url: subtitleURL, language: language, isDefault: stream["IsDefault"] as? Bool ?? false))
            }
        }
        return PlaybackInfo(url: url, itemID: id, mediaSourceID: sourceID, playSessionID: sessionID, playMethod: route.method, mimeType: route.mime, startTicks: max(0, startTicks), subtitles: subtitles, audioTracks: audio, usesMPV: route.usesMPV)
    }

    func report(event: PlaybackEvent) async throws {
        if event.playSessionID == "demo" { return }
        guard let auth = try currentAuth() else { return }
        try Self.validID(event.itemID)
        try Self.validID(event.mediaSourceID)
        let routes = ["start": "Sessions/Playing", "progress": "Sessions/Playing/Progress", "stop": "Sessions/Playing/Stopped"]
        guard let path = routes[event.type], ["DirectPlay", "DirectStream", "Transcode"].contains(event.playMethod) else {
            throw ServiceError(code: "INVALID_INPUT", message: "播放事件无效。")
        }
        let body: [String: Any] = ["ItemId": event.itemID, "MediaSourceId": event.mediaSourceID, "PlaySessionId": event.playSessionID, "PositionTicks": max(0, event.positionTicks), "PlayMethod": event.playMethod, "IsPaused": event.isPaused ?? false, "IsMuted": event.isMuted ?? false, "VolumeLevel": min(100, max(0, event.volumeLevel ?? 100)), "CanSeek": true, "QueueableMediaTypes": ["Video"], "EventName": "TimeUpdate"]
        _ = try await fetch(auth, path: path, method: "POST", body: body)
    }

    func cancelPlayback(playSessionID: String) async throws {
        if playSessionID == "demo" || playSessionID.isEmpty { return }
        guard let auth = try currentAuth() else { return }
        try Self.validID(playSessionID)
        _ = try await fetch(auth, path: "Videos/ActiveEncodings", method: "DELETE", query: ["DeviceId": deviceID, "PlaySessionId": playSessionID])
    }
}
