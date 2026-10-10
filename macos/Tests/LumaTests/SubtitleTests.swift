import Testing
import Foundation
@testable import Luma

struct SubtitleTests {
    @Test func testTimestampSettingsMarkupAndEntities() {
        let document = SubtitleDocument(webVTT: "\u{FEFF}WEBVTT\r\n\r\nintro\r\n01:02:03.500 --> 01:02:05.000 align:middle\r\n<b>Hello</b> &amp; &#x4E16;&#30028;\r\nSecond line\r\n")
        #expect(document.cues.count == 1)
        #expect(document.text(at: 3723.5) == "Hello & 世界\nSecond line")
        #expect(document.text(at: 3725) == "")
    }

    @Test func testOverlappingCuesAndSeekingBackwards() {
        let document = SubtitleDocument(webVTT: "WEBVTT\n\n00:01.000 --> 00:10.000\nLong\n\n00:02.000 --> 00:03.000\nShort\n\n00:04.000 --> 00:05.000\nLater")
        #expect(document.text(at: 4.5) == "Long\nLater")
        #expect(document.text(at: 2.5) == "Long\nShort")
        #expect(document.text(at: 3) == "Long")
        #expect(document.text(at: 0) == "")
    }

    @Test func testIgnoresMetadataAndMalformedTimestamps() {
        let document = SubtitleDocument(webVTT: "WEBVTT\n\nNOTE test\n00:00.000 --> 00:02.000\nignored\n\n00:70.000 --> 00:71.000\nbad\n\n00:05.000 --> 00:02.000\nbackwards\n\n00:01.000 --> 00:02.000\nvalid")
        #expect(document.cues.count == 1)
        #expect(document.text(at: .nan) == "")
        #expect(document.text(at: 1.5) == "valid")
    }
}

@MainActor
struct PlaybackReporterTests {
    private var info: PlaybackInfo {
        PlaybackInfo(url: URL(string: "https://example.test/video.mp4")!, itemID: "item", mediaSourceID: "source",
                     playSessionID: "session", playMethod: "DirectPlay", mimeType: "video/mp4",
                     startTicks: 10, subtitles: [], audioTracks: [])
    }

    @Test func reportsInOrderCoalescesProgressAndStopsExactlyOnce() async {
        let log = PlaybackLog()
        let reporter = PlaybackReporter(info: info, report: { await log.report($0) }, cancel: { await log.cancel($0) })
        reporter.start(positionTicks: 10)
        reporter.progress(positionTicks: 20, isPaused: false, isMuted: false, volume: 50)
        reporter.progress(positionTicks: 30, isPaused: true, isMuted: true, volume: 500)
        var completions = 0
        let finished = reporter.finish(positionTicks: 40) { completions += 1 }
        reporter.progress(positionTicks: 50, isPaused: false, isMuted: false, volume: 50)
        reporter.start(positionTicks: 60)
        reporter.finish(positionTicks: 70) { completions += 1 }
        await finished?.value
        #expect(await log.messages == ["start:10", "progress:30", "stop:40", "cancel:session"])
        #expect(await log.lastVolume == 100)
        #expect(completions == 1)
    }

    @Test func cancelledPreparationOnlyStopsTranscode() async {
        let log = PlaybackLog()
        let reporter = PlaybackReporter(info: info, report: { await log.report($0) }, cancel: { await log.cancel($0) })
        reporter.progress(positionTicks: 20, isPaused: false, isMuted: false, volume: 50)
        await reporter.finish(positionTicks: 10, completion: nil)?.value
        #expect(await log.messages == ["cancel:session"])
    }
}

private actor PlaybackLog {
    var messages: [String] = []
    var lastVolume: Int?
    func report(_ event: PlaybackEvent) async {
        // A suspended start must still precede progress and stop.
        if event.type == "start" { try? await Task.sleep(nanoseconds: 10_000_000) }
        messages.append("\(event.type):\(event.positionTicks)")
        if let volume = event.volumeLevel { lastVolume = volume }
    }
    func cancel(_ sessionID: String) { messages.append("cancel:\(sessionID)") }
}
