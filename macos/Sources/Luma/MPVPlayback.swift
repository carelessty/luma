import AppKit
import CMPV
import OpenGL.GL3
import Darwin

struct MPVTrack: Equatable, Sendable {
    let id: Int
    let title: String
    let language: String?
    let selected: Bool
}

/// Native controls own presentation; libmpv owns demuxing, decoding and subtitles.
/// No media is remuxed, written to disk, or passed to a subprocess.
@MainActor
final class MPVPlayback {
    var view: NSView { videoView }
    var onUpdate: (() -> Void)?
    var onReady: (() -> Void)?
    var onEnded: (() -> Void)?
    var onError: ((String) -> Void)?
    var onWarning: ((String) -> Void)?
    var onKeyDown: ((UInt16) -> Bool)? {
        didSet { videoView.onKeyDown = onKeyDown }
    }

    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var isPaused = true
    private(set) var isBuffering = false
    private(set) var volume = 1.0
    private(set) var isMuted = false
    private(set) var speed = 1.0
    private(set) var hardwareDecoder = ""
    private(set) var audioTracks: [MPVTrack] = []
    private(set) var subtitleTracks: [MPVTrack] = []

    private let videoView: MPVVideoView
    private let core: MPVCore
    private let renderer: MPVRenderer
    private var stopped = false

    enum PlaybackError: LocalizedError {
        case unavailable(Int32), graphicsUnavailable, stopped, invalidURL
        var errorDescription: String? {
            switch self {
            case .unavailable(let code): return L10n.playback("error.mpv.initialization", code)
            case .graphicsUnavailable: return L10n.playback("error.mpv.graphics")
            case .stopped: return L10n.playback("error.mpv.stopped")
            case .invalidURL: return L10n.playback("error.mpv.invalid.url")
            }
        }
    }

    init() throws {
        let videoView = try MPVVideoView.make()
        let core = try MPVCore()
        let renderer: MPVRenderer
        do {
            renderer = try MPVRenderer(handle: core.handle, context: videoView.openGLContext!)
        } catch {
            core.shutdown()
            throw error
        }
        self.videoView = videoView
        self.core = core
        self.renderer = renderer
        videoView.renderer = renderer
        core.deliver = { [weak self] snapshot, event in
            guard let self, !self.stopped else { return }
            self.position = snapshot.position
            self.duration = snapshot.duration
            self.isPaused = snapshot.paused
            self.isBuffering = snapshot.loading || snapshot.seeking || snapshot.cachePaused
            self.volume = snapshot.volume
            self.isMuted = snapshot.muted
            self.speed = snapshot.speed
            self.hardwareDecoder = snapshot.hardwareDecoder
            self.audioTracks = snapshot.audioTracks
            self.subtitleTracks = snapshot.subtitleTracks
            self.onUpdate?()
            switch event {
            case .ready: self.onReady?()
            case .ended: self.onEnded?()
            case .error(let code): self.onError?(L10n.playback("error.mpv.decode", code))
            case .warning(let code): self.onWarning?(L10n.playback("error.mpv.operation", code))
            case .update: break
            }
        }
        core.startEvents()
    }

    deinit {
        // The GL context must be freed before mpv's core. Both expensive steps
        // execute off the main thread and retain their callback storage to exit.
        let core = core
        renderer.stop { core.shutdown() }
    }

    func load(url: URL, startSeconds: Double, paused: Bool, defaultSubtitles: Bool) throws {
        guard !stopped else { throw PlaybackError.stopped }
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw PlaybackError.invalidURL
        }
        position = startSeconds.isFinite ? max(0, startSeconds) : 0
        isPaused = paused
        isBuffering = true
        core.load(url: url, start: position, paused: paused, subtitles: defaultSubtitles)
        onUpdate?()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        videoView.onKeyDown = nil
        let core = core
        renderer.stop { core.shutdown() }
    }

    func setPaused(_ paused: Bool) {
        guard !stopped else { return }
        isPaused = paused
        core.setFlag("pause", paused)
    }

    func seek(seconds: Double) {
        guard !stopped, seconds.isFinite else { return }
        core.command(["seek", String(max(0, seconds)), "absolute+exact"])
    }

    func setVolume(_ value: Double) {
        guard !stopped, value.isFinite else { return }
        volume = min(1, max(0, value))
        core.setDouble("volume", volume * 100)
    }

    func setMuted(_ muted: Bool) {
        guard !stopped else { return }
        isMuted = muted
        core.setFlag("mute", muted)
    }

    func setSpeed(_ value: Double) {
        guard !stopped, value.isFinite else { return }
        speed = min(4, max(0.25, value))
        core.setDouble("speed", speed)
    }

    func selectAudio(id: Int) {
        guard !stopped else { return }
        core.command(["set", "aid", String(id)])
    }

    func selectSubtitle(id: Int?) {
        guard !stopped else { return }
        core.command(["set", "sid", id.map(String.init) ?? "no"])
    }

    func addSubtitle(url: URL, title: String) {
        guard !stopped, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        // Re-select an already loaded sidecar instead of downloading and adding
        // it again each time the server's subtitle menu item is chosen.
        core.command(["sub-add", url.isFileURL ? url.path : url.absoluteString, "cached", title])
    }
}

private struct MPVSnapshot: Sendable {
    var position = 0.0
    var duration = 0.0
    var paused = true
    var loading = false
    var seeking = false
    var cachePaused = false
    var volume = 1.0
    var muted = false
    var speed = 1.0
    var hardwareDecoder = ""
    var audioTracks: [MPVTrack] = []
    var subtitleTracks: [MPVTrack] = []
}

private enum MPVNotification: Sendable {
    case update, ready, ended, error(Int32), warning(Int32)
}

/// The C callback only signals a dispatch source. It never enters either mpv
/// API, and its storage remains alive until the owning C context is destroyed.
private final class MPVSignal: @unchecked Sendable {
    let source: DispatchSourceUserDataAdd
    init(queue: DispatchQueue) {
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.activate()
    }
    func notify() { source.add(data: 1) }
    static let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
        guard let pointer else { return }
        Unmanaged<MPVSignal>.fromOpaque(pointer).takeUnretainedValue().notify()
    }
    var opaque: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

private final class MPVCore: @unchecked Sendable {
    let handle: OpaquePointer
    var deliver: (@MainActor @Sendable (MPVSnapshot, MPVNotification) -> Void)?
    private let queue = DispatchQueue(label: "io.luma.mpv.events", qos: .userInitiated)
    private let signal: MPVSignal
    private var destroyed = false // Only accessed on queue after initialization.
    private var state = MPVSnapshot()
    private var waitingForFirstFrame = false
    private var failureReported = false
    private var nextSubtitleRequest: UInt64 = 10
    private var pendingSubtitleRequest: UInt64?
    private var cancelledSubtitleRequests: Set<UInt64> = []

    init() throws {
        guard let handle = mpv_create() else { throw MPVPlayback.PlaybackError.unavailable(-2) }
        self.handle = handle
        signal = MPVSignal(queue: queue)
        let options = [
            "config": "no", "load-scripts": "no", "ytdl": "no",
            "terminal": "no", "msg-level": "all=no", "osc": "no",
            "input-default-bindings": "no", "input-vo-keyboard": "no",
            "input-cursor": "no", "osd-level": "0", "vo": "libmpv",
            "hwdec": "videotoolbox", "hwdec-codecs": "all",
            "cache": "yes", "cache-on-disk": "no", "cache-secs": "30",
            "demuxer-max-bytes": "64MiB", "demuxer-max-back-bytes": "32MiB",
            "network-timeout": "15", "idle": "yes", "keep-open": "no",
            // Homebrew's OpenSSL build does not read Keychain trust. Use the
            // OS-provided CA bundle so HTTPS verification also works after install.
            "tls-verify": "yes", "tls-ca-file": "/etc/ssl/cert.pem",
            "save-position-on-quit": "no", "sub-auto": "no", "audio-file-auto": "no",
            "video-sync": "audio", "sub-ass": "yes"
        ]
        for (name, value) in options {
            let result = mpv_set_option_string(handle, name, value)
            if result < 0 {
                mpv_terminate_destroy(handle)
                throw MPVPlayback.PlaybackError.unavailable(result)
            }
        }
        let result = mpv_initialize(handle)
        guard result >= 0 else {
            mpv_terminate_destroy(handle)
            throw MPVPlayback.PlaybackError.unavailable(result)
        }
        let properties: [(String, mpv_format)] = [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
            ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG),
            ("volume", MPV_FORMAT_DOUBLE), ("mute", MPV_FORMAT_FLAG),
            ("speed", MPV_FORMAT_DOUBLE), ("hwdec-current", MPV_FORMAT_STRING),
            ("track-list", MPV_FORMAT_NODE)
        ]
        for (index, property) in properties.enumerated() {
            mpv_observe_property(handle, UInt64(index + 1), property.0, property.1)
        }
    }

    func startEvents() {
        signal.source.setEventHandler { [weak self] in self?.drainEvents() }
        mpv_set_wakeup_callback(handle, MPVSignal.callback, signal.opaque)
    }

    func load(url: URL, start: Double, paused: Bool, subtitles: Bool) {
        queue.async { [self] in
            guard !destroyed else { return }
            state.position = start
            state.loading = true
            state.paused = paused
            waitingForFirstFrame = true
            failureReported = false
            let settings = "start=\(start),pause=\(paused ? "yes" : "no"),sid=\(subtitles ? "auto" : "no")"
            // The options are a separate argument; the URL is never shell-parsed.
            commandNow(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace", "-1", settings])
        }
    }

    func command(_ arguments: [String]) {
        queue.async { [self] in
            guard !destroyed else { return }
            let addsSubtitle = arguments.first == "sub-add"
            let selectsSubtitle = arguments.count > 1 && arguments[0] == "set" && arguments[1] == "sid"
            if addsSubtitle || selectsSubtitle, let previous = pendingSubtitleRequest {
                // A slow subtitle fetch must not turn captions back on after
                // the user has switched tracks or explicitly disabled them.
                cancelledSubtitleRequests.insert(previous)
                mpv_abort_async_command(handle, previous)
                pendingSubtitleRequest = nil
            }
            if addsSubtitle {
                nextSubtitleRequest += 1
                pendingSubtitleRequest = nextSubtitleRequest
                commandNow(arguments, requestID: nextSubtitleRequest)
            } else {
                commandNow(arguments)
            }
        }
    }

    private func commandNow(_ arguments: [String], requestID: UInt64? = nil) {
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = strings.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        } + [nil]
        let isLoad = arguments.first == "loadfile"
        let result = mpv_command_async(handle, requestID ?? (isLoad ? 1 : 2), &pointers)
        if result < 0 {
            if requestID == pendingSubtitleRequest { pendingSubtitleRequest = nil }
            emit(isLoad ? .error(result) : .warning(result))
        }
    }

    func setFlag(_ name: String, _ value: Bool) {
        queue.async { [self] in
            guard !destroyed else { return }
            var flag: Int32 = value ? 1 : 0
            mpv_set_property_async(handle, 0, name, MPV_FORMAT_FLAG, &flag)
        }
    }

    func setDouble(_ name: String, _ value: Double) {
        queue.async { [self] in
            guard !destroyed else { return }
            var number = value
            mpv_set_property_async(handle, 0, name, MPV_FORMAT_DOUBLE, &number)
        }
    }

    func shutdown() {
        queue.async { [self] in
            guard !destroyed else { return }
            destroyed = true
            mpv_set_wakeup_callback(handle, nil, nil)
            signal.source.cancel()
            mpv_terminate_destroy(handle)
        }
    }

    private func emit(_ event: MPVNotification) {
        if case .error = event {
            guard !failureReported else { return }
            failureReported = true
        }
        let snapshot = state
        let callback = deliver
        DispatchQueue.main.async { callback?(snapshot, event) }
    }

    private func drainEvents() {
        guard !destroyed else { return }
        var changed = false
        while let pointer = mpv_wait_event(handle, 0), pointer.pointee.event_id != MPV_EVENT_NONE {
            let event = pointer.pointee
            switch event.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = event.data {
                    readProperty(data.assumingMemoryBound(to: mpv_event_property.self).pointee)
                    changed = true
                }
            case MPV_EVENT_START_FILE:
                state.loading = true
                changed = true
            case MPV_EVENT_FILE_LOADED:
                changed = true
            case MPV_EVENT_SEEK:
                state.seeking = true
                changed = true
            case MPV_EVENT_PLAYBACK_RESTART:
                state.loading = false
                state.seeking = false
                changed = true
                if waitingForFirstFrame {
                    waitingForFirstFrame = false
                    emit(.ready)
                }
            case MPV_EVENT_END_FILE:
                state.loading = false
                state.seeking = false
                state.cachePaused = false
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    if end.reason == MPV_END_FILE_REASON_EOF { emit(.ended) }
                    else if end.reason == MPV_END_FILE_REASON_ERROR { emit(.error(end.error)) }
                }
            case MPV_EVENT_COMMAND_REPLY:
                if pendingSubtitleRequest == event.reply_userdata { pendingSubtitleRequest = nil }
                if cancelledSubtitleRequests.remove(event.reply_userdata) != nil { continue }
                if event.error < 0 { emit(event.reply_userdata == 1 ? .error(event.error) : .warning(event.error)) }
            case MPV_EVENT_SET_PROPERTY_REPLY:
                if event.error < 0 { emit(.warning(event.error)) }
            default: break
            }
        }
        if changed { emit(.update) }
    }

    private func readProperty(_ property: mpv_event_property) {
        guard let name = property.name, let data = property.data else { return }
        let nameString = String(cString: name)
        if property.format == MPV_FORMAT_DOUBLE {
            let number = data.assumingMemoryBound(to: Double.self).pointee
            guard number.isFinite else { return }
            switch nameString {
            case "time-pos": state.position = max(0, number)
            case "duration": state.duration = max(0, number)
            case "volume": state.volume = min(1, max(0, number / 100))
            case "speed": state.speed = number
            default: break
            }
        } else if property.format == MPV_FORMAT_FLAG {
            let flag = data.assumingMemoryBound(to: Int32.self).pointee != 0
            switch nameString {
            case "pause": state.paused = flag
            case "paused-for-cache": state.cachePaused = flag
            case "mute": state.muted = flag
            default: break
            }
        } else if property.format == MPV_FORMAT_STRING, nameString == "hwdec-current" {
            if let string = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                state.hardwareDecoder = String(cString: string)
            }
        } else if property.format == MPV_FORMAT_NODE, nameString == "track-list" {
            let node = data.assumingMemoryBound(to: mpv_node.self).pointee
            state.audioTracks = Self.tracks(in: node, type: "audio")
            state.subtitleTracks = Self.tracks(in: node, type: "sub")
        }
    }

    private static func tracks(in node: mpv_node, type: String) -> [MPVTrack] {
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee,
              let values = list.values, list.num > 0 else { return [] }
        return (0..<Int(list.num)).compactMap { index in
            let map = values[index]
            guard map.format == MPV_FORMAT_NODE_MAP, let entries = map.u.list?.pointee,
                  let keys = entries.keys, let values = entries.values, entries.num > 0 else { return nil }
            var fields: [String: mpv_node] = [:]
            for field in 0..<Int(entries.num) {
                if let key = keys[field] { fields[String(cString: key)] = values[field] }
            }
            func string(_ key: String) -> String? {
                guard let value = fields[key], value.format == MPV_FORMAT_STRING, let text = value.u.string else { return nil }
                return String(cString: text)
            }
            guard string("type") == type, let identifier = fields["id"], identifier.format == MPV_FORMAT_INT64 else { return nil }
            let id = Int(identifier.u.int64)
            let language = string("lang")
            let title = string("title").flatMap { $0.isEmpty ? nil : $0 }
                ?? [language, string("codec")?.uppercased()].compactMap { $0 }.joined(separator: " · ")
            let selected = fields["selected"].map { $0.format == MPV_FORMAT_FLAG && $0.u.flag != 0 } ?? false
            return MPVTrack(id: id, title: title.isEmpty ? L10n.playback(type == "audio" ? "track.audio.numbered" : "track.subtitle.numbered", id) : title,
                            language: language, selected: selected)
        }
    }
}

@MainActor
private final class MPVVideoView: NSOpenGLView {
    var renderer: MPVRenderer?
    var onKeyDown: ((UInt16) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    static func make() throws -> MPVVideoView {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFAAllowOfflineRenderers), UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8, 0
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes), let view = MPVVideoView(format: format) else {
            throw MPVPlayback.PlaybackError.graphicsUnavailable
        }
        return view
    }

    private init?(format: NSOpenGLPixelFormat) {
        super.init(frame: .zero, pixelFormat: format)
        guard openGLContext != nil else { return nil }
        wantsBestResolutionOpenGLSurface = true
        setAccessibilityLabel(L10n.playback("accessibility.video"))
        var interval: GLint = 1
        openGLContext?.setValues(&interval, for: .swapInterval)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) { redraw() }
    override func reshape() {
        withLockedContext { super.reshape() }
        redraw()
    }
    override func update() { withLockedContext { super.update() } }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { window?.toggleFullScreen(nil) }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           onKeyDown?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }

    private func redraw() {
        let pixels = convertToBacking(bounds).size
        renderer?.redraw(width: max(1, Int(pixels.width)), height: max(1, Int(pixels.height)))
    }

    private func withLockedContext(_ body: () -> Void) {
        guard let context = openGLContext?.cglContextObj else { body(); return }
        CGLLockContext(context)
        defer { CGLUnlockContext(context) }
        body()
    }
}

/// OpenGL work and vsync execute on their own serial queue, never on AppKit's
/// event thread. mpv client calls likewise run on a different queue, as required
/// by libmpv's render API to avoid a render/core lock dependency.
private final class MPVRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.luma.mpv.render", qos: .userInteractive)
    private let gl: NSOpenGLContext
    private var context: OpaquePointer?
    private let signal: MPVSignal
    private let stopLock = NSLock()
    private var stopped = false
    private var width = 1
    private var height = 1

    init(handle: OpaquePointer, context: NSOpenGLContext) throws {
        gl = context
        signal = MPVSignal(queue: queue)
        var result: Int32 = -1
        queue.sync {
            withContext {
                var initParameters = mpv_opengl_init_params(get_proc_address: { _, name in
                    guard let name else { return nil }
                    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
                }, get_proc_address_ctx: nil)
                result = "opengl".withCString { api in
                    withUnsafeMutablePointer(to: &initParameters) { parameters in
                        var options = [
                            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: parameters),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                        ]
                        return mpv_render_context_create(&self.context, handle, &options)
                    }
                }
            }
        }
        guard result >= 0, self.context != nil else {
            signal.source.cancel()
            throw MPVPlayback.PlaybackError.graphicsUnavailable
        }
        signal.source.setEventHandler { [weak self] in self?.render(force: false) }
        queue.sync {
            withContext { mpv_render_context_set_update_callback(self.context, MPVSignal.callback, signal.opaque) }
        }
    }

    func redraw(width: Int, height: Int) {
        queue.async { [self] in
            self.width = width
            self.height = height
            render(force: true)
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        stopLock.lock()
        if stopped { stopLock.unlock(); return }
        stopped = true
        stopLock.unlock()
        queue.async { [self] in
            withContext {
                if let context {
                    mpv_render_context_set_update_callback(context, nil, nil)
                    mpv_render_context_free(context)
                    self.context = nil
                }
            }
            signal.source.cancel()
            completion()
        }
    }

    private func render(force: Bool) {
        guard let context else { return }
        withContext {
            let flags = mpv_render_context_update(context)
            guard force || flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
            var fbo = mpv_opengl_fbo(fbo: 0, w: Int32(width), h: Int32(height), internal_format: 0)
            var flip: Int32 = 1
            var block: Int32 = 0
            withUnsafeMutablePointer(to: &fbo) { fboPointer in
                withUnsafeMutablePointer(to: &flip) { flipPointer in
                    withUnsafeMutablePointer(to: &block) { blockPointer in
                        var options = [
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPointer),
                            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockPointer),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                        ]
                        mpv_render_context_render(context, &options)
                    }
                }
            }
            gl.flushBuffer()
            mpv_render_context_report_swap(context)
        }
    }

    private func withContext(_ body: () -> Void) {
        guard let cgl = gl.cglContextObj else { return }
        CGLLockContext(cgl)
        defer { NSOpenGLContext.clearCurrentContext(); CGLUnlockContext(cgl) }
        gl.makeCurrentContext()
        body()
    }
}
