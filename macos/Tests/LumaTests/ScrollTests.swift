import AppKit
import Testing
@testable import Luma

@MainActor
private final class ScrollReceiver: NSScrollView {
    var received: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { received.append(event) }
}

@MainActor
// AppKit tracks an active scroll gesture across windows; overlapping synthetic
// gestures in different tests can cancel each other's native scroll animation.
@Suite(.serialized)
struct ScrollTests {
    private func shelf() -> (ScrollReceiver, MediaScrollView, NSWindow) {
        _ = NSApplication.shared
        let parent = ScrollReceiver(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        parent.hasVerticalScroller = true
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 1500))
        parent.documentView = page
        let shelf = MediaScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 220))
        shelf.forwardsVerticalScrolling = true
        shelf.hasHorizontalScroller = true
        shelf.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 2400, height: 200))
        page.addSubview(shelf)
        let window = NSWindow(contentRect: parent.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = parent
        parent.layoutSubtreeIfNeeded()
        shelf.contentView.scroll(to: NSPoint(x: 500, y: 0))
        return (parent, shelf, window)
    }

    private func event(x: Int32 = 0, y: Int32 = 0, units: CGScrollEventUnit = .pixel, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        if let phase { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        if let momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue)) }
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func mouseWheelOverShelfScrollsThePage() throws {
        let (page, shelf, window) = shelf()
        defer { window.close() }
        let down = try event(y: -3, units: .line)
        let up = try event(y: 3, units: .line)
        #expect(!down.hasPreciseScrollingDeltas)
        #expect(!up.hasPreciseScrollingDeltas)
        shelf.scrollWheel(with: down)
        shelf.scrollWheel(with: up)
        #expect(page.received.count == 2)
        #expect(page.received[0] === down)
        #expect(page.received[1] === up)
    }

    @Test func precisePixelWheelOverShelfKeepsTheOriginalEvent() throws {
        let (page, shelf, window) = shelf()
        defer { window.close() }
        let pixel = try event(y: -30)
        #expect(pixel.hasPreciseScrollingDeltas)
        shelf.scrollWheel(with: pixel)
        #expect(page.received.count == 1)
        #expect(page.received.first === pixel)
    }

    @Test func verticalTrackpadGestureKeepsItsAxisThroughMomentum() throws {
        let (page, shelf, window) = shelf()
        defer { window.close() }
        let events = try [
            event(x: 1, y: -20, phase: .began),
            event(x: 8, y: -3, phase: .changed),
            event(phase: .ended),
            event(y: -15, momentum: .begin),
            event(x: 3, y: -1, momentum: CGMomentumScrollPhase(rawValue: 2)),
            event(momentum: .end)
        ]
        for event in events { shelf.scrollWheel(with: event) }
        #expect(page.received.count == events.count)

        // A subsequent horizontal gesture belongs to the shelf, even if its
        // later deltas lean vertically. Complete the synthetic gesture so its
        // AppKit animation state cannot leak into another window/test.
        for event in try [
            event(x: -20, y: 1, phase: .began),
            event(x: -3, y: 20, phase: .changed),
            event(phase: .ended),
            event(x: -15, y: 1, momentum: .begin),
            event(x: -1, y: 12, momentum: CGMomentumScrollPhase(rawValue: 2)),
            event(momentum: .end)
        ] { shelf.scrollWheel(with: event) }
        #expect(page.received.count == events.count)
        // Native phased animation on a hidden window has no guaranteed 100 ms
        // completion. Actual native scrolling is checked with the independent
        // mouse wheel below; this test checks the complete routing sequence.
    }

    @Test func independentHorizontalWheelMovesShelfAfterVerticalGesture() throws {
        let (page, shelf, window) = shelf()
        defer { window.close() }
        shelf.scrollWheel(with: try event(y: -20, phase: .began))
        shelf.scrollWheel(with: try event(phase: .ended))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.07))
        let previousX = shelf.contentView.bounds.origin.x
        let right = try event(x: -30)
        #expect(right.scrollingDeltaX < 0)
        shelf.scrollWheel(with: right)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(page.received.count == 2)
        #expect(shelf.contentView.bounds.origin.x > previousX)
    }
}
