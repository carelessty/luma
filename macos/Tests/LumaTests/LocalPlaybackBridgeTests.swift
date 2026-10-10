import Foundation
import Testing
import Darwin
@testable import Luma

@Suite(.serialized)
struct LocalPlaybackBridgeTests {
    @Test(.enabled(if: LocalPlaybackBridge.converterURL != nil))
    func stoppedBridgeRejectsPreparationAndRepeatedStopsAreHarmless() async {
        let bridge = LocalPlaybackBridge()
        bridge.stop()
        bridge.stop()
        let preparation = Task { try await bridge.prepare(sourceURL: URL(fileURLWithPath: "/unused-fixture.mkv")) }
        let result = await preparationResult(preparation)
        switch result {
        case .success: Issue.record("A stopped bridge must not restart conversion")
        case .failure(let error):
            guard case LocalPlaybackBridge.BridgeError.stopped = error else {
                Issue.record("Expected stopped, received \(error)")
                return
            }
        }
        #expect(bridge.failureDescription == nil)
    }

    @Test(.enabled(if: LocalPlaybackBridge.converterURL != nil))
    func cancellingBlockedPreparationReleasesContinuationProcessAndCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("luma-cancel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // An unopened FIFO holds FFmpeg in input preparation without networking,
        // credentials or timing assumptions about a real media server.
        let source = directory.appendingPathComponent("blocked.mkv")
        try #require(mkfifo(source.path, 0o600) == 0)
        let bridge = LocalPlaybackBridge()
        defer { bridge.stop() }
        let cache = bridge.cacheDirectory
        let preparation = Task { try await bridge.prepare(sourceURL: source, videoCodec: "hevc") }
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: cache.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: cache.path), "Preparation must reach its resource-owning phase")
        // Closing a paused player must resume the child long enough to terminate it.
        bridge.setPaused(true)
        preparation.cancel()
        let result = await preparationResult(preparation)
        switch result {
        case .success: Issue.record("An input with no bytes cannot complete preparation")
        case .failure(let error):
            #expect(error is CancellationError || {
                if case LocalPlaybackBridge.BridgeError.stopped = error { return true }
                return false
            }(), "Cancellation must complete without waiting for the normal conversion timeout")
        }
        bridge.stop()
        bridge.stop()
        for _ in 0..<60 {
            if !FileManager.default.fileExists(atPath: cache.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(bridge.failureDescription == nil)
    }

    @Test(.enabled(if: LocalPlaybackBridge.converterURL != nil))
    func remuxesHEVCAndFLACAndServesOnlyItsPrivateMediaFiles() async throws {
        let converter = try #require(LocalPlaybackBridge.converterURL)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("luma-bridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.mkv")
        let generator = Process()
        generator.executableURL = converter
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                               "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "40",
                               "-c:v", "libx265", "-preset", "ultrafast", "-x265-params",
                               "log-level=error:keyint=48:min-keyint=48:scenecut=0:pools=1:frame-threads=1",
                               "-pix_fmt", "yuv420p10le", "-c:a", "flac", source.path]
        generator.standardOutput = FileHandle.nullDevice
        generator.standardError = FileHandle.nullDevice
        try generator.run()
        generator.waitUntilExit()
        try #require(generator.terminationStatus == 0)

        let bridge = LocalPlaybackBridge()
        defer { bridge.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 6
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try await bridge.prepare(sourceURL: source, videoCodec: "hevc")
        #expect(url.host == "127.0.0.1")
        #expect(url.port != nil)
        let (playlist, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: playlist, as: UTF8.self).contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(!String(decoding: playlist, as: UTF8.self).contains("#EXT-X-ENDLIST"))
        #expect(!bridge.requiresRestartOnResume)

        let initURL = url.deletingLastPathComponent().appendingPathComponent("init.mp4")
        var range = URLRequest(url: initURL)
        range.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        let (bytes, rangeResponse) = try await session.data(for: range)
        #expect((rangeResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(bytes.count == 16)
        var head = URLRequest(url: initURL)
        head.httpMethod = "HEAD"
        let (headBytes, headResponse) = try await session.data(for: head)
        #expect((headResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(headBytes.isEmpty)
        let (_, forbidden) = try await session.data(from: url.deletingLastPathComponent().appendingPathComponent("fixture.mkv"))
        #expect((forbidden as? HTTPURLResponse)?.statusCode == 404)
        let (_, wrongRoute) = try await session.data(from: url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("stream.m3u8"))
        #expect((wrongRoute as? HTTPURLResponse)?.statusCode == 404)

        bridge.setPaused(true)
        #expect(bridge.requiresRestartOnResume)
        let (pausedPlaylist, _) = try await session.data(from: url)
        #expect(String(decoding: pausedPlaylist, as: UTF8.self).contains("#EXT-X-ENDLIST"))
        bridge.setPaused(false)
        #expect(bridge.requiresRestartOnResume)
        let (stillFrozenPlaylist, _) = try await session.data(from: url)
        #expect(stillFrozenPlaylist == pausedPlaylist, "A resumed movie needs a new URL, never a VOD-to-live mutation")

        let completedBridge = LocalPlaybackBridge()
        defer { completedBridge.stop() }
        let completedURL = try await completedBridge.prepare(sourceURL: source, startTicks: 390_000_000, videoCodec: "hevc")
        let (completedPlaylist, _) = try await session.data(from: completedURL)
        try #require(String(decoding: completedPlaylist, as: UTF8.self).contains("#EXT-X-ENDLIST"))
        completedBridge.setPaused(true)
        #expect(!completedBridge.requiresRestartOnResume, "Natural EOF must remain eligible for next-episode playback")
        let (pausedAtRealEnd, _) = try await session.data(from: completedURL)
        #expect(pausedAtRealEnd == completedPlaylist)

        let slowBridge = LocalPlaybackBridge()
        defer { slowBridge.stop() }
        let slowURL = try await slowBridge.prepare(sourceURL: source, videoCodec: "hevc", readRate: 0.5)
        let (slowManifest, _) = try await session.data(from: slowURL)
        let slowText = String(decoding: slowManifest, as: UTF8.self)
        let target = try #require(slowText.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") })?
            .split(separator: ":").last.flatMap { Double($0) })
        let longestSegment = slowText.components(separatedBy: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).split(separator: ",").first ?? "") }.max() ?? 0
        #expect(longestSegment > 0)
        #expect(target >= ceil(longestSegment / 0.5), "Reload deadline must account for slow segment production")
        slowBridge.setPaused(true)
        let (slowPausedManifest, _) = try await session.data(from: slowURL)
        #expect(String(decoding: slowPausedManifest, as: UTF8.self).contains("#EXT-X-TARGETDURATION:\(Int(target))"))
        #expect(String(decoding: slowPausedManifest, as: UTF8.self).contains("#EXT-X-ENDLIST"))

        bridge.stop()
        do {
            _ = try await session.data(from: url)
            Issue.record("A stopped bridge must close its loopback listener")
        } catch { }
    }

    /// Do not let a regression involving an unresumed continuation hang the test
    /// runner. This intentionally does not await the losing, cancelled task.
    private func preparationResult(_ preparation: Task<URL, Error>) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            let outcome = PreparationOutcome(continuation)
            Task { outcome.resolve(await preparation.result) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                outcome.resolve(.failure(URLError(.timedOut)))
                preparation.cancel()
            }
        }
    }
}

private final class PreparationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<URL, Error>, Never>?
    init(_ continuation: CheckedContinuation<Result<URL, Error>, Never>) { self.continuation = continuation }
    func resolve(_ result: Result<URL, Error>) {
        lock.lock()
        let completion = continuation
        continuation = nil
        lock.unlock()
        completion?.resume(returning: result)
    }
}
