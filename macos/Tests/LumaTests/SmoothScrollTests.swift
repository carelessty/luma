import AppKit
import Testing
@testable import Luma

@MainActor
private final class SmoothScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ScrollBoundsRecorder {
    private var token: NSObjectProtocol?
    var positions: [NSPoint] = []

    init(_ clip: NSClipView) {
        clip.postsBoundsChangedNotifications = true
        token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                       object: clip, queue: .main) { [weak self, weak clip] _ in
            MainActor.assumeIsolated {
                if let clip {
                    self?.positions.append(clip.bounds.origin)
                }
            }
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

// Share the serialized suite with nested shelf routing: AppKit maintains
// scroll gesture state across windows.
extension ScrollTests {
    private struct Fixture {
        let window: NSWindow
        let scroll: SmoothScrollView
        let recorder: ScrollBoundsRecorder
    }

    private func fixture(flipped: Bool = true) -> Fixture {
        _ = NSApplication.shared
        let scroll = SmoothScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        scroll.hasVerticalScroller = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        let frame = NSRect(x: 0, y: 0, width: 420, height: 2600)
        scroll.documentView = flipped ? SmoothScrollDocument(frame: frame) : NSView(frame: frame)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 280),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Luma 滚动回归测试"
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        // Give AppKit an opportunity to attach the view to its display. The
        // assertions below use bounds notifications, not a presumed refresh rate.
        pumpNativeEvents(for: 0.07)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        return Fixture(window: window, scroll: scroll, recorder: ScrollBoundsRecorder(scroll.contentView))
    }

    private func smoothEvent(y: Int32 = 0, units: CGScrollEventUnit = .line,
                       phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units,
                                     wheelCount: 2, wheel1: y, wheel2: 0, wheel3: 0))
        if let phase { cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue)) }
        if let momentum { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue)) }
        return try #require(NSEvent(cgEvent: cg))
    }

    private func waitUntil(_ condition: () -> Bool) {
        for _ in 0..<200 {
            if condition() { return }
            pumpNativeEvents(for: 0.01)
        }
    }

    // Keep AppKit event delivery and animation waits on its native run loop.
    // Suspending an async command-line test after synthetic precise scrolling
    // can end the AppKit process before the continuation resumes.
    private func pumpNativeEvents(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    @Test func motionHasContinuousMonotonicPositionsAndExactEndpoints() {
        let motion = WheelScrollMotion(start: NSPoint(x: 10, y: 100), target: NSPoint(x: 30, y: 140), startTime: 5)
        #expect(motion.position(at: 4) == motion.start)
        #expect(motion.position(at: 5) == motion.start)
        let positions = (1...7).map { motion.position(at: 5 + WheelScrollMotion.duration * Double($0) / 8) }
        #expect(positions.allSatisfy { $0.x > 10 && $0.x < 30 && $0.y > 100 && $0.y < 140 })
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0.0.y < $0.1.y })
        #expect(motion.position(at: 5 + WheelScrollMotion.duration) == motion.target)
        #expect(motion.position(at: 6) == motion.target)
        #expect(!motion.isFinished(at: 5))
        #expect(motion.isFinished(at: 6))
    }

    @Test func motionAccumulatesSameDirectionAndReversesFromVisiblePosition() {
        let current = NSPoint(x: 20, y: 100)
        let pending = NSPoint(x: 50, y: 150)
        #expect(WheelScrollMotion.destination(from: current, pending: nil, delta: NSPoint(x: 10, y: 20)) == NSPoint(x: 30, y: 120))
        #expect(WheelScrollMotion.destination(from: current, pending: pending, delta: NSPoint(x: 10, y: 20)) == NSPoint(x: 60, y: 170))
        #expect(WheelScrollMotion.destination(from: current, pending: pending, delta: NSPoint(x: -10, y: -20)) == NSPoint(x: 10, y: 80))
    }

    @Test func remoteWheelSensitivityPreservesCombinedInputAndRejectsInvalidSettings() {
        let scale = WheelScrollSettings.validatedMultiplier(0.25)
        #expect(720 * scale == 180)
        #expect(1440 * scale == 360)
        #expect(WheelScrollSettings.validatedMultiplier(nil) == 1)
        #expect(WheelScrollSettings.validatedMultiplier(.nan) == 1)
        #expect(WheelScrollSettings.validatedMultiplier(-1) == 1)
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    func lineWheelProducesIntermediateBoundsAndPreservesNativeDistance() throws {
        let fixture = fixture()
        defer { fixture.window.close() }
        let scroll = fixture.scroll
        let start = scroll.contentView.bounds.origin.y
        let wheel = try smoothEvent(y: -3)
        #expect(!wheel.hasPreciseScrollingDeltas)
        let target = start + 3 * scroll.verticalLineScroll
        scroll.scrollWheel(with: wheel)
        let immediate = scroll.contentView.bounds.origin.y
        #expect(immediate == start, "Discrete input should schedule motion, not jump to its destination")
        waitUntil { abs(scroll.contentView.bounds.origin.y - target) < 0.01 }
        #expect(abs(scroll.contentView.bounds.origin.y - target) < 0.01)
        let samples = fixture.recorder.positions.map(\.y)
        let intermediate = Set(samples.filter { $0 > start && $0 < target })
        #expect(intermediate.count >= 2, "Bounds notifications should expose continuous intermediate positions")
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }

    @Test func pixelInputImmediatelyBeforeEveryFrameDoesNotStarveProgress() {
        var visible = NSPoint.zero
        var motion: WheelScrollMotion?
        let delta = NSPoint(x: 0, y: 4)
        for tick in 0..<60 {
            let time = Double(tick) / 60
            let target = WheelScrollMotion.destination(from: visible, pending: motion?.target, delta: delta)
            let start = motion?.retargetingOrigin(visible: visible, delta: delta, at: time) ?? visible
            let next = WheelScrollMotion(start: start, target: target, startTime: time,
                                         interval: WheelScrollMotion.pixelDuration)
            visible = next.position(at: time + 0.0002)
            motion = next
        }
        #expect(visible.y > 220, "A 240 pt scroll stream must not stall behind just-before-frame input")
        #expect(visible.y < 240)
        #expect(motion?.position(at: 2).y == 240)
        #expect(motion?.retargetingOrigin(visible: visible, delta: NSPoint(x: 0, y: -4), at: 1) == visible,
                "Direction reversal still starts from the visible position")
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    func unphasedPixelInputInterpolatesPointsWithoutLineMultiplication() throws {
        let fixture = fixture()
        defer { fixture.window.close() }
        let scroll = fixture.scroll
        scroll.verticalLineScroll = 40
        let wheel = try smoothEvent(y: -120, units: .pixel)
        #expect(wheel.hasPreciseScrollingDeltas)
        #expect(wheel.phase.isEmpty && wheel.momentumPhase.isEmpty)
        scroll.scrollWheel(with: wheel)
        #expect(scroll.contentView.bounds.origin.y == 500)
        waitUntil { abs(scroll.contentView.bounds.origin.y - 620) < 0.01 }
        #expect(abs(scroll.contentView.bounds.origin.y - 620) < 0.01)
        #expect(fixture.recorder.positions.contains { $0.y > 500 && $0.y < 620 })
        #expect(fixture.recorder.positions.allSatisfy { $0.y <= 620 })

        for _ in 0..<3 { scroll.scrollWheel(with: try smoothEvent(y: -20, units: .pixel)) }
        waitUntil { abs(scroll.contentView.bounds.origin.y - 680) < 0.01 }
        #expect(abs(scroll.contentView.bounds.origin.y - 680) < 0.01)
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    func wheelBurstsAccumulateAndReversedTicksDoNotFinishOldMotion() throws {
        let fixture = fixture()
        defer { fixture.window.close() }
        let scroll = fixture.scroll
        for _ in 0..<3 { scroll.scrollWheel(with: try smoothEvent(y: -2)) }
        let target = 500 + 6 * scroll.verticalLineScroll
        waitUntil { abs(scroll.contentView.bounds.origin.y - target) < 0.01 }
        #expect(abs(scroll.contentView.bounds.origin.y - target) < 0.01)

        scroll.scrollWheel(with: try smoothEvent(y: -20))
        waitUntil { scroll.contentView.bounds.origin.y > target + 1 }
        let reversedAt = scroll.contentView.bounds.origin.y
        try #require(reversedAt < target + 20 * scroll.verticalLineScroll)
        fixture.recorder.positions.removeAll()
        scroll.scrollWheel(with: try smoothEvent(y: 2))
        let reversedTarget = reversedAt - 2 * scroll.verticalLineScroll
        waitUntil { abs(scroll.contentView.bounds.origin.y - reversedTarget) < 0.01 }
        #expect(abs(scroll.contentView.bounds.origin.y - reversedTarget) < 0.01)
        #expect(fixture.recorder.positions.allSatisfy { $0.y <= reversedAt })
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    func boundaryClampingAndUnflippedDocumentsKeepCorrectCoordinates() throws {
        let fixture = fixture()
        defer { fixture.window.close() }
        let scroll = fixture.scroll
        var farBounds = scroll.contentView.bounds
        farBounds.origin.y = 1_000_000
        let bottom = scroll.contentView.constrainBoundsRect(farBounds).origin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom - 3))
        scroll.scrollWheel(with: try smoothEvent(y: -10))
        waitUntil { abs(scroll.contentView.bounds.origin.y - bottom) < 0.01 }
        #expect(abs(scroll.contentView.bounds.origin.y - bottom) < 0.01)
        #expect(fixture.recorder.positions.allSatisfy { $0.y <= bottom })
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 3))
        scroll.scrollWheel(with: try smoothEvent(y: 10))
        waitUntil { abs(scroll.contentView.bounds.origin.y) < 0.01 }
        #expect(abs(scroll.contentView.bounds.origin.y) < 0.01)

        let unflipped = self.fixture(flipped: false)
        defer { unflipped.window.close() }
        unflipped.scroll.scrollWheel(with: try smoothEvent(y: -3))
        let target = 500 - 3 * unflipped.scroll.verticalLineScroll
        waitUntil { abs(unflipped.scroll.contentView.bounds.origin.y - target) < 0.01 }
        #expect(abs(unflipped.scroll.contentView.bounds.origin.y - target) < 0.01)
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    func externalBoundsChangeWinsAndNextWheelStartsFromNewPosition() throws {
        let fixture = fixture()
        defer { fixture.window.close() }
        let scroll = fixture.scroll
        scroll.scrollWheel(with: try smoothEvent(y: -20))
        waitUntil { scroll.contentView.bounds.origin.y > 501 }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1200))
        scroll.reflectScrolledClipView(scroll.contentView)
        pumpNativeEvents(for: 0.3)
        #expect(scroll.contentView.bounds.origin.y == 1200)
        scroll.scrollWheel(with: try smoothEvent(y: -1))
        let target = 1200 + scroll.verticalLineScroll
        waitUntil { abs(scroll.contentView.bounds.origin.y - target) < 0.01 }
        #expect(abs(scroll.contentView.bounds.origin.y - target) < 0.01)
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    func detachingAndReleasingAnAnimatingViewDoesNotRetainIt() throws {
        weak var weakScroll: SmoothScrollView?
        try autoreleasepool {
            let fixture = fixture()
            weakScroll = fixture.scroll
            fixture.scroll.scrollWheel(with: try smoothEvent(y: -20))
            fixture.window.contentView = nil
            fixture.window.close()
        }
        waitUntil { weakScroll == nil }
        #expect(weakScroll == nil, "Display link, timer and callback proxy must not retain a detached scroll view")
    }
}
