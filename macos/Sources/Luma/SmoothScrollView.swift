import AppKit
import QuartzCore

/// Interpolates wheel input without gesture phases, including pixel-based
/// injected input. Phased gestures retain AppKit's native momentum handling.
class SmoothScrollView: NSScrollView {
    private var motion: WheelScrollMotion?
    private var lastAppliedOrigin: NSPoint?
    private var stopFrames: (() -> Void)?

    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    override var documentView: NSView? {
        didSet { cancelWheelAnimation() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelWheelAnimation()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidHide() {
        cancelWheelAnimation()
        super.viewDidHide()
    }

    deinit { stopFrames?() }

    override func scrollWheel(with event: NSEvent) {
        guard event.phase.isEmpty, event.momentumPhase.isEmpty,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              window != nil, let documentView else {
            cancelWheelAnimation()
            super.scrollWheel(with: event)
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion { cancelWheelAnimation() }
        let origin = contentView.bounds.origin
        if let lastAppliedOrigin, origin != lastAppliedOrigin { cancelWheelAnimation() }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.modifierFlags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
        // Precise means points, not necessarily smooth: remote input can
        // arrive in isolated pixel-sized steps without a gesture lifecycle.
        let pixelScale = WheelScrollSettings.pixelMultiplier
        let xScale: CGFloat = event.hasPreciseScrollingDeltas ? pixelScale : horizontalLineScroll
        let yScale: CGFloat = event.hasPreciseScrollingDeltas ? pixelScale : verticalLineScroll
        let delta = NSPoint(x: hasHorizontalScroller ? -dx * xScale : 0,
                            y: hasVerticalScroller ? dy * yScale * (documentView.isFlipped ? -1 : 1) : 0)
        guard delta.x.isFinite, delta.y.isFinite, delta != .zero else {
            super.scrollWheel(with: event)
            return
        }

        let destination = WheelScrollMotion.destination(from: origin, pending: motion?.target, delta: delta)
        let target = constrainedOrigin(destination)
        guard target != origin else { cancelWheelAnimation(); return }
        if reduceMotion {
            contentView.scroll(to: target)
            reflectScrolledClipView(contentView)
            return
        }
        let now = CACurrentMediaTime()
        let start = motion?.retargetingOrigin(visible: origin, delta: delta, at: now) ?? origin
        motion = WheelScrollMotion(start: constrainedOrigin(start), target: target, startTime: now,
                                   interval: event.hasPreciseScrollingDeltas ? WheelScrollMotion.pixelDuration : WheelScrollMotion.duration)
        lastAppliedOrigin = origin
        startFramesIfNeeded()
    }

    private func constrainedOrigin(_ origin: NSPoint) -> NSPoint {
        var bounds = contentView.bounds
        bounds.origin = origin
        return contentView.constrainBoundsRect(bounds).origin
    }

    private func startFramesIfNeeded() {
        guard stopFrames == nil else { return }
        if #available(macOS 14.0, *) {
            // The display link owns this proxy, which only weakly captures us.
            let proxy = WheelFrameTarget { [weak self] in self?.advanceWheelAnimation() }
            let link = displayLink(target: proxy, selector: #selector(WheelFrameTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            stopFrames = { link.invalidate() }
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.advanceWheelAnimation()
            }
            RunLoop.main.add(timer, forMode: .common)
            stopFrames = { timer.invalidate() }
        }
    }

    private func advanceWheelAnimation() {
        guard let motion, window?.isVisible == true,
              contentView.bounds.origin == lastAppliedOrigin else {
            // A scroller drag, keyboard navigation or programmatic scroll wins
            // immediately; an old wheel target must never pull it back.
            cancelWheelAnimation()
            return
        }
        let now = CACurrentMediaTime()
        let origin = constrainedOrigin(motion.position(at: now))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        lastAppliedOrigin = contentView.bounds.origin
        if motion.isFinished(at: now) { cancelWheelAnimation() }
    }

    private func cancelWheelAnimation() {
        stopFrames?()
        stopFrames = nil
        motion = nil
        lastAppliedOrigin = nil
    }
}

enum WheelScrollSettings {
    static let preferenceKey = "luma.native.pixelWheelMultiplier"
    static let multipliers: [Double] = [0.125, 0.25, 0.5, 1]

    static func validatedMultiplier(_ value: Double?) -> CGFloat {
        guard let value, multipliers.contains(value) else { return 1 }
        return CGFloat(value)
    }

    static var pixelMultiplier: CGFloat {
        get { validatedMultiplier(UserDefaults.standard.object(forKey: preferenceKey) as? Double) }
        set { UserDefaults.standard.set(Double(validatedMultiplier(Double(newValue))), forKey: preferenceKey) }
    }
}

private final class WheelFrameTarget: NSObject {
    private let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    @objc func tick(_ sender: Any) { callback() }
}

struct WheelScrollMotion {
    let start: NSPoint
    let target: NSPoint
    let startTime: CFTimeInterval
    let interval: CFTimeInterval
    static let duration: CFTimeInterval = 0.16
    static let pixelDuration: CFTimeInterval = 0.08

    init(start: NSPoint, target: NSPoint, startTime: CFTimeInterval,
         interval: CFTimeInterval = WheelScrollMotion.duration) {
        self.start = start
        self.target = target
        self.startTime = startTime
        self.interval = interval
    }

    func position(at time: CFTimeInterval) -> NSPoint {
        let progress = min(1, max(0, (time - startTime) / interval))
        let eased = 1 - pow(1 - progress, 3)
        return NSPoint(x: start.x + (target.x - start.x) * eased,
                       y: start.y + (target.y - start.y) * eased)
    }

    func isFinished(at time: CFTimeInterval) -> Bool { time >= startTime + interval }

    func retargetingOrigin(visible: NSPoint, delta: NSPoint, at time: CFTimeInterval) -> NSPoint {
        let interpolated = position(at: time)
        // Input may arrive just before every display callback. Preserve the
        // elapsed interpolation between inputs, rather than restarting from
        // the previous frame each time and starving visible progress.
        func next(_ visible: CGFloat, _ target: CGFloat, _ delta: CGFloat, _ interpolated: CGFloat) -> CGFloat {
            delta * (target - visible) < 0 ? visible : interpolated
        }
        return NSPoint(x: next(visible.x, target.x, delta.x, interpolated.x),
                       y: next(visible.y, target.y, delta.y, interpolated.y))
    }

    static func destination(from current: NSPoint, pending: NSPoint?, delta: NSPoint) -> NSPoint {
        func next(_ current: CGFloat, _ pending: CGFloat?, _ delta: CGFloat) -> CGFloat {
            guard let pending else { return current + delta }
            // A reversed wheel starts moving back now, without paying off
            // accumulated motion in the previous direction first.
            return (delta * (pending - current) < 0 ? current : pending) + delta
        }
        return NSPoint(x: next(current.x, pending?.x, delta.x),
                       y: next(current.y, pending?.y, delta.y))
    }
}
