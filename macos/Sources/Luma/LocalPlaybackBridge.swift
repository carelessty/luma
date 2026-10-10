import Foundation
import Network

/// Remuxes unsupported containers locally without decoding/re-encoding the video.
/// Each bridge owns one FFmpeg process, one private loopback endpoint and its cache.
final class LocalPlaybackBridge: @unchecked Sendable {
    enum BridgeError: LocalizedError {
        case missingConverter, conversionFailed(Int32), timedOut, stopped
        var errorDescription: String? {
            switch self {
            case .missingConverter: return "本地兼容播放需要 FFmpeg。请安装 FFmpeg 后重试。"
            case .conversionFailed(let code): return "本地媒体转换失败（\(code)），请重试或选择其他版本。"
            case .timedOut: return "本地媒体转换等待超时，请检查网络后重试。"
            case .stopped: return "播放准备已取消。"
            }
        }
    }

    static var converterURL: URL? {
        let paths: [String?] = [Bundle.main.url(forAuxiliaryExecutable: "ffmpeg")?.path,
                     "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private let queue = DispatchQueue(label: "io.luma.local-playback", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let directory: URL
    private let route = UUID().uuidString
    private var process: Process?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    private var preparing = false
    private var processExit: Int32?
    private var startupContinuation: CheckedContinuation<URL, Error>?
    private var pausedPlaylist: Data?
    private var restartRequired = false
    private var inputReadRate: Double = 1

    /// Read-only location for verifying the lifetime and size of this bridge's
    /// generated media cache without inspecting other running playback sessions.
    var cacheDirectory: URL { directory }

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("luma-playback-\(UUID().uuidString)", isDirectory: true)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    /// AVPlayer's resulting timeline begins at zero; add startTicks when reporting
    /// the original movie's position. Stream copy seeks at the preceding keyframe.
    func prepare(sourceURL: URL, startTicks: Int64 = 0, videoCodec: String? = nil, readRate: Double = 1) async throws -> URL {
        guard let executable = Self.converterURL else { throw BridgeError.missingConverter }
        let rate = readRate.isFinite ? min(4, max(0.25, readRate)) : 1
        let initialBurst = 16 / min(1, rate)
        let playlist = directory.appendingPathComponent("stream.m3u8")
        let url: URL = try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.stopped, !self.preparing else { continuation.resume(throwing: BridgeError.stopped); return }
                self.preparing = true
                self.inputReadRate = rate
                self.startupContinuation = continuation
                do {
                    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    let route = self.route
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self, self.startupContinuation != nil else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port else { return }
                            self.completeStartup(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/\(route)/stream.m3u8")!))
                        case .failed(let error): self.completeStartup(.failure(error)); self.stop()
                        case .cancelled: self.completeStartup(.failure(BridgeError.stopped))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.start(queue: self.queue)

                    let process = Process()
                    process.executableURL = executable
                    process.currentDirectoryURL = self.directory
                    var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
                    if sourceURL.scheme == "https" || sourceURL.scheme == "http" {
                        arguments += ["-rw_timeout", "20000000", "-user_agent", "Luma/1.0 AppKit"]
                    }
                    if startTicks > 0 { arguments += ["-ss", String(Double(startTicks) / 10_000_000)] }
                    arguments += ["-readrate", String(rate), "-readrate_catchup", String(rate * 1.5),
                                  "-readrate_initial_burst", String(initialBurst)]
                    arguments += ["-i", sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString,
                                  "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn",
                                  "-c:v", "copy"]
                    if ["hevc", "h265"].contains(videoCodec?.lowercased() ?? "") { arguments += ["-tag:v", "hvc1"] }
                    arguments += ["-c:a", "aac", "-b:a", "192k", "-ac", "2",
                                  "-avoid_negative_ts", "make_zero", "-f", "hls", "-hls_time", "4",
                                  "-hls_segment_type", "fmp4", "-hls_list_size", String(max(15, Int(ceil(initialBurst / 4)) + 3)), "-hls_delete_threshold", "3",
                                  "-hls_flags", "delete_segments+temp_file", "-hls_fmp4_init_filename", "init.mp4",
                                  "-hls_segment_filename", "segment%06d.m4s", "stream.m3u8"]
                    process.arguments = arguments
                    // FFmpeg diagnostics can include credential-bearing input URLs.
                    // Surface only the exit code, never its raw stderr.
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.terminationHandler = { [weak self, directory = self.directory] process in
                        guard let self else { try? FileManager.default.removeItem(at: directory); return }
                        self.queue.async {
                            self.processExit = process.terminationStatus
                            if self.stopped { try? FileManager.default.removeItem(at: self.directory) }
                        }
                    }
                    self.process = process
                    try process.run()
                    self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, self.startupContinuation != nil else { return }
                        self.completeStartup(.failure(BridgeError.timedOut))
                        self.stop()
                    }
                } catch {
                    self.completeStartup(.failure(error))
                    self.stop()
                    self.processExit = -1
                }
            }
          }
        } onCancel: {
            self.stop()
        }
        do {
            for _ in 0..<600 {
                try Task.checkCancellation()
                let status = queue.sync { (stopped, processExit) }
                if status.0 { throw BridgeError.stopped }
                if let code = status.1, code != 0 { throw BridgeError.conversionFailed(code) }
                if let text = try? String(contentsOf: playlist, encoding: .utf8),
                   text.contains("#EXTINF:"),
                   FileManager.default.fileExists(atPath: directory.appendingPathComponent("init.mp4").path) {
                    return url
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw BridgeError.timedOut
        } catch { stop(); throw error }
    }

    func stop() {
        let cleanup = { [self] in
            guard !stopped else { return }
            stopped = true
            completeStartup(.failure(BridgeError.stopped))
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            if let process, process.isRunning {
                kill(process.processIdentifier, SIGCONT)
                process.terminate()
                let pid = process.processIdentifier
                queue.asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            } else { try? FileManager.default.removeItem(at: directory) }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { cleanup() } else { queue.sync(execute: cleanup) }
    }

    /// All startup paths converge here on the serial queue, including cancellation
    /// before NWListener becomes ready. A continuation is consumed exactly once.
    private func completeStartup(_ result: Result<URL, Error>) {
        guard let continuation = startupContinuation else { return }
        startupContinuation = nil
        listener?.stateUpdateHandler = nil
        continuation.resume(with: result)
    }

    /// Keep a paused movie's buffered segments instead of consuming the network
    /// and evicting them while the user is away.
    func setPaused(_ paused: Bool) {
        queue.async {
            guard !self.stopped else { return }
            if paused, !self.restartRequired {
                // A completed conversion already has its real ENDLIST. Pausing
                // at natural EOF must not suppress episode completion/auto-next.
                guard self.processExit != 0 else { return }
                let playlist = try? String(contentsOf: self.directory.appendingPathComponent("stream.m3u8"), encoding: .utf8)
                if playlist?.contains("#EXT-X-ENDLIST") == true { return }
                self.restartRequired = true
                if let text = playlist {
                    // A paused live playlist otherwise fails in AVFoundation once
                    // it remains unchanged for several target durations. This URL
                    // now represents only its frozen, finite buffered window.
                    self.pausedPlaylist = Data((text + "\n#EXT-X-ENDLIST\n").utf8)
                }
                if let process = self.process, process.isRunning { kill(process.processIdentifier, SIGSTOP) }
            } else if !paused, !self.restartRequired, let process = self.process, process.isRunning {
                kill(process.processIdentifier, SIGCONT)
            }
        }
    }

    /// Once a live URL has become a paused VOD snapshot it must never be reused
    /// as a live stream. Resume by preparing a new bridge at the original position.
    var requiresRestartOnResume: Bool {
        DispatchQueue.getSpecific(key: queueKey) == true ? restartRequired : queue.sync { restartRequired }
    }

    var failureDescription: String? {
        let read = { [self] in
            guard !stopped, let code = processExit, code != 0 else { return nil as String? }
            return BridgeError.conversionFailed(code).errorDescription
        }
        return DispatchQueue.getSpecific(key: queueKey) == true ? read() : queue.sync(execute: read)
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
            if case .failed = state { connection?.cancel(); self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        receive(connection, data: Data())
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            let request = data + (chunk ?? Data())
            guard request.count <= 16_384 else { self.reply(connection, code: 431); return }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") { self.serve(connection, request: text) }
            else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, data: request) }
        }
    }

    private func serve(_ connection: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET" || first[0] == "HEAD" else { reply(connection, code: 405); return }
        let prefix = "/\(route)/"
        guard first[1].hasPrefix(prefix) else { reply(connection, code: 404); return }
        let filename = String(first[1].dropFirst(prefix.count))
        guard filename == "stream.m3u8" || filename == "init.mp4" ||
                filename.range(of: "^segment[0-9]{6}\\.m4s$", options: .regularExpression) != nil else { reply(connection, code: 404); return }
        guard let rawData = filename == "stream.m3u8" && pausedPlaylist != nil ? pausedPlaylist :
                (try? Data(contentsOf: directory.appendingPathComponent(filename), options: .mappedIfSafe)) else { reply(connection, code: 404); return }
        let data = filename == "stream.m3u8" ? servedManifest(rawData) : rawData
        let mime = filename.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4"
        var lower = 0, upper = data.count - 1, code = 200
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = range.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("bytes="), !value.contains(",") else { reply(connection, code: 416); return }
            let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2 else { reply(connection, code: 416); return }
            if bounds[0].isEmpty, let length = Int(bounds[1]), length > 0 { lower = max(0, data.count - length) }
            else if let start = Int(bounds[0]) { lower = start; if !bounds[1].isEmpty { upper = Int(bounds[1]) ?? -1 } }
            else { reply(connection, code: 416); return }
            upper = min(upper, data.count - 1)
            guard lower >= 0, lower <= upper else { reply(connection, code: 416); return }
            code = 206
        }
        let body = data.isEmpty ? Data() : data.subdata(in: lower..<(upper + 1))
        let extra = code == 206 ? "Content-Range: bytes \(lower)-\(upper)/\(data.count)\r\n" : ""
        reply(connection, code: code, content: first[0] == "HEAD" ? Data() : body,
              headers: "Content-Type: \(mime)\r\nAccept-Ranges: bytes\r\n\(extra)", length: body.count)
    }

    private func reply(_ connection: NWConnection, code: Int, content: Data = Data(), headers: String = "", length: Int? = nil) {
        let header = "HTTP/1.1 \(code) Response\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Length: \(length ?? content.count)\r\n\(headers)\r\n"
        connection.send(content: Data(header.utf8) + content, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func servedManifest(_ data: Data) -> Data {
        guard inputReadRate < 1, let text = String(data: data, encoding: .utf8) else { return data }
        let prefix = "#EXT-X-TARGETDURATION:"
        // Slow playback also produces segments less often in wall-clock time.
        // Give AVFoundation a matching reload window rather than allowing an
        // otherwise healthy 0.5× stream to look like an unchanged/stalled live feed.
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard line.hasPrefix(prefix), let duration = Double(line.dropFirst(prefix.count)),
                  duration.isFinite, duration > 0, duration < Double(Int.max / 4) else { return line }
            return prefix + String(Int(ceil(duration / inputReadRate)))
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
