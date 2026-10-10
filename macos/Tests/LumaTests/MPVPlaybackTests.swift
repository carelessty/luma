import AppKit
import Foundation
import Network
import Testing
@testable import Luma

@Suite(.serialized)
@MainActor
struct MPVPlaybackTests {
    @Test(.enabled(if: LocalPlaybackBridge.converterURL != nil))
    func directlyDecodesMKVWithResumeSeekTracksAndNoIntermediateMedia() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("luma-mpv-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.mkv")
        let subtitles = directory.appendingPathComponent("captions.ass")
        try """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 160
        PlayResY: 90
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,12,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,2,2,3,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:12.00,Default,,0,0,0,,Luma embedded ASS
        """.write(to: subtitles, atomically: true, encoding: .utf8)
        let bilingual = directory.appendingPathComponent("bilingual.ass")
        let chinese = directory.appendingPathComponent("chinese.ass")
        let assSource = try String(contentsOf: subtitles, encoding: .utf8)
        try assSource.replacingOccurrences(of: "Luma embedded ASS", with: "双语字幕\\NEnglish subtitle")
            .write(to: bilingual, atomically: true, encoding: .utf8)
        try assSource.replacingOccurrences(of: "Luma embedded ASS", with: "仅中文字幕")
            .write(to: chinese, atomically: true, encoding: .utf8)
        let converter = try #require(LocalPlaybackBridge.converterURL)
        let generated = try await Task.detached {
            let process = Process()
            process.executableURL = converter
            process.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24",
                                 "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                                 "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000", "-i", subtitles.path,
                                 "-i", bilingual.path, "-i", chinese.path,
                                 "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map", "4:s", "-map", "5:s", "-t", "12",
                                 "-c:v", "libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le",
                                 "-x265-params", "log-level=error:keyint=24:pools=1:frame-threads=1",
                                 "-c:a", "flac", "-c:s", "ass", "-metadata:s:a:0", "language=eng",
                                 "-metadata:s:a:1", "language=zho", "-metadata:s:s:0", "title=chs&eng",
                                 "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "title=chs&eng",
                                 "-metadata:s:s:1", "language=zho", "-metadata:s:s:2", "title=chs",
                                 "-metadata:s:s:2", "language=zho", "-disposition:s:0", "default",
                                 "-disposition:s:1", "0", "-disposition:s:2", "0",
                                 source.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        try #require(generated == 0)

        let player = try MPVPlayback()
        defer { player.stop() }
        var ready = false
        var error: String?
        var firstPosition = -1.0
        player.onReady = { [weak player] in ready = true; firstPosition = player?.position ?? -1 }
        player.onError = { error = $0 }
        try player.load(url: source, startSeconds: 3.5, paused: true, defaultSubtitles: true)
        try await waitFor { ready || error != nil }
        try #require(error == nil)
        try #require(ready)
        #expect(abs(firstPosition - 3.5) < 0.3)
        #expect(player.isPaused)
        #expect(abs(player.duration - 12) < 0.3)
        try await waitFor { player.audioTracks.count == 2 && player.subtitleTracks.count == 3 }
        #expect(player.audioTracks.count == 2)
        #expect(player.subtitleTracks.count == 3)
        #expect(player.subtitleTracks.prefix(2).map(\.title) == ["chs&eng", "chs&eng"],
                "Distinct tracks with duplicate titles must keep their independent IDs")
        #expect(player.hardwareDecoder == "videotoolbox", "Supported HEVC must use VideoToolbox directly")

        let thirdSubtitle = try #require(player.subtitleTracks.last)
        #expect(thirdSubtitle.title == "chs")
        player.selectSubtitle(id: thirdSubtitle.id)
        try await waitFor { player.subtitleTracks.first(where: { $0.selected })?.id == thirdSubtitle.id }
        #expect(player.subtitleTracks.filter(\.selected).map(\.id) == [thirdSubtitle.id])
        let secondAudio = try #require(player.audioTracks.last)
        player.selectAudio(id: secondAudio.id)
        try await waitFor { player.audioTracks.contains { $0.id == secondAudio.id && $0.selected } }
        #expect(player.audioTracks.contains { $0.id == secondAudio.id && $0.selected })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(player.subtitleTracks.filter(\.selected).map(\.id) == [thirdSubtitle.id],
                "Switching audio from English to Chinese must preserve the explicitly chosen third subtitle")
        player.selectSubtitle(id: nil)
        try await waitFor { player.subtitleTracks.allSatisfy { !$0.selected } }
        #expect(player.subtitleTracks.allSatisfy { !$0.selected })

        player.setSpeed(1.5)
        player.setVolume(0.25)
        player.setMuted(true)
        player.seek(seconds: 9)
        try await waitFor { abs(player.position - 9) < 0.25 && !player.isBuffering }
        #expect(abs(player.position - 9) < 0.25)
        #expect(player.isPaused)
        player.setPaused(false)
        try await waitFor { player.position > 9.3 }
        #expect(player.position > 9.3)
        player.setPaused(true)
        try await Task.sleep(nanoseconds: 200_000_000)
        let pausedPosition = player.position
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(abs(player.position - pausedPosition) < 0.05)
        #expect(player.speed == 1.5)
        #expect(player.volume == 0.25)
        #expect(player.isMuted)

        let external = directory.appendingPathComponent("external.srt")
        try "1\n00:00:00,000 --> 00:00:12,000\nExternal subtitle\n".write(to: external, atomically: true, encoding: .utf8)
        player.addSubtitle(url: external, title: "External SRT")
        try await waitFor { player.subtitleTracks.contains { $0.title == "External SRT" && $0.selected } }
        #expect(player.subtitleTracks.contains { $0.title == "External SRT" && $0.selected })
        let loadedSubtitleCount = player.subtitleTracks.count
        player.selectSubtitle(id: nil)
        try await waitFor { player.subtitleTracks.allSatisfy { !$0.selected } }
        player.addSubtitle(url: external, title: "External SRT")
        try await waitFor { player.subtitleTracks.contains { $0.title == "External SRT" && $0.selected } }
        #expect(player.subtitleTracks.count == loadedSubtitleCount, "Re-selecting a sidecar must reuse its existing track")
        var warning: String?
        player.onWarning = { warning = $0 }
        player.addSubtitle(url: directory.appendingPathComponent("unavailable-private-token.srt"), title: "Unavailable")
        try await waitFor { warning != nil }
        #expect(warning != nil)
        #expect(warning?.contains("private-token") == false)
        #expect(error == nil)

        let delayed = try DelayedMPVSubtitleServer()
        defer { delayed.stop() }
        try await waitFor { delayed.port != nil }
        let port = try #require(delayed.port)
        let delayedURL = try #require(URL(string: "http://127.0.0.1:\(port)/slow.srt"))
        player.addSubtitle(url: delayedURL, title: "Slow subtitle")
        try await waitFor { delayed.receivedRequest }
        try #require(delayed.receivedRequest)
        player.selectSubtitle(id: nil)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(player.subtitleTracks.allSatisfy { !$0.selected }, "A cancelled slow subtitle must not turn captions back on")
        #expect(error == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(files) == ["fixture.mkv", "captions.ass", "bilingual.ass", "chinese.ass", "external.srt"])
        player.stop()
        player.stop()
        #expect(throws: MPVPlayback.PlaybackError.self) {
            try player.load(url: source, startSeconds: 0, paused: false, defaultSubtitles: false)
        }
        // Shutdown is asynchronous; retained callback storage must survive it.
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test
    func decoderErrorsNeverExposeAnAuthenticatedURLAndStopCancelsCallbacks() async throws {
        _ = NSApplication.shared
        let player = try MPVPlayback()
        defer { player.stop() }
        var reportedError: String?
        var updates = 0
        player.onError = { reportedError = $0 }
        player.onUpdate = { updates += 1 }
        let privatePath = URL(fileURLWithPath: "/luma-missing-fixture-private-token-\(UUID().uuidString).mkv")
        try player.load(url: privatePath, startSeconds: 0, paused: false, defaultSubtitles: false)
        try await waitFor { reportedError != nil }
        let message = try #require(reportedError)
        #expect(!message.contains("private-token"))
        #expect(!message.contains(privatePath.path))
        player.stop()
        let countAtStop = updates
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(updates == countAtStop)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private final class DelayedMPVSubtitleServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.luma.tests.slow-subtitle")
    private let lock = NSLock()
    private var didReceive = false
    private var connections: [NWConnection] = []
    var port: UInt16? {
        guard let port = listener.port?.rawValue, port > 0 else { return nil }
        return port
    }
    var receivedRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didReceive
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
                guard let self, data != nil else { connection.cancel(); return }
                self.lock.lock()
                self.didReceive = true
                self.lock.unlock()
                self.queue.asyncAfter(deadline: .now() + 1) {
                    let body = "1\n00:00:00,000 --> 00:00:12,000\nDelayed caption\n"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}
