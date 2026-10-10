import Foundation
import Testing
@testable import Luma

@MainActor
struct PlaybackTests {
    @Test func progressReceivedDuringAnInFlightReportReachesServerBeforeStop() async {
        let log = SuspendedPlaybackReports()
        let info = PlaybackInfo(url: URL(string: "https://fixture.invalid/movie.mp4")!,
                                itemID: "movie", mediaSourceID: "source", playSessionID: "session",
                                playMethod: "DirectPlay", mimeType: "video/mp4", startTicks: 0,
                                subtitles: [], audioTracks: [])
        let reporter = PlaybackReporter(info: info, report: { await log.report($0) },
                                        cancel: { await log.cancel($0) })
        reporter.start(positionTicks: 0)
        reporter.progress(positionTicks: 10, isPaused: false, isMuted: false, volume: 100)
        await log.waitUntilProgressIsInFlight()
        reporter.progress(positionTicks: 20, isPaused: false, isMuted: false, volume: 100)
        reporter.progress(positionTicks: 30, isPaused: true, isMuted: true, volume: 25)
        let completion = reporter.finish(positionTicks: 30, completion: nil)
        await log.releaseProgress()
        await completion?.value

        #expect(await log.messages == ["start:0", "progress:10", "progress:30", "stop:30", "cancel:session"])
        #expect(await log.lastProgress?.isPaused == true)
        #expect(await log.lastProgress?.isMuted == true)
        #expect(await log.lastProgress?.volumeLevel == 25)
    }
}

private actor SuspendedPlaybackReports {
    var messages: [String] = []
    var lastProgress: PlaybackEvent?
    private var isInFlight = false
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func report(_ event: PlaybackEvent) async {
        messages.append("\(event.type):\(event.positionTicks)")
        guard event.type == "progress" else { return }
        lastProgress = event
        guard !isInFlight else { return }
        isInFlight = true
        await withCheckedContinuation { continuation in
            release = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilProgressIsInFlight() async {
        guard !isInFlight else { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseProgress() {
        release?.resume()
        release = nil
    }

    func cancel(_ id: String) { messages.append("cancel:\(id)") }
}
