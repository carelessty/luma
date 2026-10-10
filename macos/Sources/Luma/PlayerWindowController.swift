import AppKit
import AVKit
import AVFoundation
import MediaPlayer

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onPlaybackStopped: (() -> Void)?
    /// Called with the completed episode. The library controller chooses the next episode.
    var onNextEpisode: ((MediaItem) -> Void)?

    private let service: MediaService
    private let playerView = AVPlayerView()
    private let localVideoView = NativeVideoView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let subtitleMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let audioMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let captionView = CaptionView()
    private let demoLabel = NSTextField(labelWithString: "")
    private let sourceTimeline = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let sourceTime = NSTextField(labelWithString: "00:00 / 00:00")
    private let localPlayPause = NSButton()
    private let localVolume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let localControls = NSStackView()
    private let localSpeed = NSPopUpButton(frame: .zero, pullsDown: false)
    private var savedSubtitleKey: String?
    private var playerBottom: NSLayoutConstraint?
    private var localBridge: LocalPlaybackBridge?
    private var sourceOffsetTicks: Int64 = 0
    private var startPaused = false
    private var savedVolume: Float = 1
    private var savedMuted = false
    private var localPaused = false
    private var desiredRate: Float = 1
    private var defaultRateObservation: NSKeyValueObservation?
    private var player: AVPlayer?
    private var mpv: MPVPlayback?
    private var mpvTrackSignature = ""
    private var mpvControlSignature = ""
    private var item: MediaItem?
    private var preferences = Preferences()
    private var info: PlaybackInfo?
    private var reporter: PlaybackReporter?
    private var generation = UUID()
    private var hasStarted = false
    private var isStarting = false
    private var lastPositionTicks: Int64 = 0
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var subtitleTask: Task<Void, Never>?
    private var subtitleGeneration = UUID()
    private var subtitleDocument: SubtitleDocument?
    private var subtitleChoices: [SubtitleChoice] = [.off]
    private var subtitleGroup: AVMediaSelectionGroup?
    private var lastReport = Date.distantPast
    private var lastNowPlayingUpdate = Date.distantPast
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var finishingTasks: [UUID: Task<Void, Never>] = [:]
    private var preparingTasks: [UUID: Task<Void, Never>] = [:]

    private enum SubtitleChoice {
        case off
        case embedded(AVMediaSelectionOption)
        case external(SubtitleTrack)
        case mpv(Int)
    }

    init(service: MediaService) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Luma 播放器"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrameAutosaveName("LumaPlayerWindow")
        if !window.setFrameUsingName("LumaPlayerWindow") { window.center() }
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func play(_ item: MediaItem, preferences: Preferences, paused: Bool = false, presentWindow: Bool = true) {
        let retainedSubtitle = !presentWindow && self.item?.id == item.id ? savedSubtitleKey : nil
        stop()
        savedSubtitleKey = retainedSubtitle
        self.item = item
        self.preferences = preferences
        self.startPaused = paused
        lastPositionTicks = max(0, item.positionTicks)
        let ticket = generation
        window?.title = item.title
        if presentWindow {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        setMessage("正在准备播放…", loading: true)
        // Let a superseded request complete so its server transcode can be stopped.
        preparingTasks[ticket] = Task { [weak self] in
            guard let self else { return }
            defer { self.preparingTasks.removeValue(forKey: ticket) }
            do {
                let info = try await service.playback(id: item.id,
                                                      maxBitrate: min(200, max(1, preferences.maxBitrateMbps)) * 1_000_000,
                                                      startTicks: max(0, item.positionTicks))
                guard generation == ticket else {
                    try? await service.cancelPlayback(playSessionID: info.playSessionID)
                    return
                }
                if info.usesMPV {
                    do { try installMPV(info, ticket: ticket) }
                    catch {
                        try? await service.cancelPlayback(playSessionID: info.playSessionID)
                        throw error
                    }
                } else if info.requiresLocalConversion {
                    setMessage("正在准备兼容播放…", loading: true)
                    let bridge = LocalPlaybackBridge()
                    localBridge = bridge
                    do {
                        let url = try await bridge.prepare(sourceURL: info.url, startTicks: info.startTicks, videoCodec: info.localVideoCodec, readRate: Double(desiredRate))
                        guard generation == ticket else {
                            bridge.stop()
                            try? await service.cancelPlayback(playSessionID: info.playSessionID)
                            return
                        }
                        sourceOffsetTicks = max(0, info.startTicks)
                        var localInfo = info
                        localInfo.url = url
                        localInfo.startTicks = 0
                        install(localInfo, ticket: ticket)
                    } catch {
                        bridge.stop()
                        try? await service.cancelPlayback(playSessionID: info.playSessionID)
                        throw error
                    }
                } else {
                    install(info, ticket: ticket)
                }
            } catch {
                guard generation == ticket else { return }
                setMessage((error as? LocalizedError)?.errorDescription ?? "无法准备视频，请检查服务器连接后重试。", loading: false, retry: true)
            }
        }
    }

    /// Call before disconnecting the account, or when the application terminates.
    func stop() {
        generation = UUID()
        subtitleGeneration = UUID()
        subtitleTask?.cancel()
        subtitleTask = nil
        let finalPosition = positionTicks()
        // Retry a failed stream from the position reached in this window, rather
        // than the stale library progress captured when playback was opened.
        if hasStarted, info?.isDemo != true { item?.positionTicks = finalPosition }
        statusObservation = nil
        rateObservation = nil
        defaultRateObservation = nil
        if let periodicObserver, let player { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        if let player { savedVolume = player.volume; savedMuted = player.isMuted }
        if let mpv { savedVolume = Float(mpv.volume); savedMuted = mpv.isMuted }
        player?.pause()
        if let reporter {
            let callback = onPlaybackStopped
            let identifier = UUID()
            finishingTasks[identifier] = reporter.finish(positionTicks: finalPosition) { [weak self] in
                self?.finishingTasks.removeValue(forKey: identifier)
                callback?()
            }
        }
        reporter = nil
        // Detach the view before releasing the player. Clearing its item while
        // AVKit's timeline is still bound can leave system controls reading an
        // invalid time during a local-stream restart.
        playerView.player = nil
        localVideoView.playerLayer.player = nil
        player = nil
        mpv?.onUpdate = nil
        mpv?.onReady = nil
        mpv?.onEnded = nil
        mpv?.onError = nil
        mpv?.onWarning = nil
        mpv?.view.removeFromSuperview()
        mpv?.stop()
        mpv = nil
        mpvTrackSignature = ""
        localBridge?.stop()
        localBridge = nil
        sourceOffsetTicks = 0
        localPaused = false
        localControls.isHidden = true
        playerBottom?.constant = 0
        info = nil
        hasStarted = false
        isStarting = false
        subtitleDocument = nil
        subtitleGroup = nil
        captionView.text = ""
        demoLabel.isHidden = true
        window?.subtitle = ""
        resetSubtitleMenu()
        audioMenu.removeAllItems()
        audioMenu.addItem(withTitle: "音轨")
        audioMenu.isEnabled = false
        spinner.stopAnimation(nil)
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Keep the account alive until pending stop reports and transcode cleanup finish.
    func stopAndWait() async {
        stop()
        let preparation = Array(preparingTasks.values)
        for task in preparation { await task.value }
        let tasks = Array(finishingTasks.values)
        for task in tasks { await task.value }
    }

    func windowWillClose(_ notification: Notification) { stop() }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        // Supply the library title and system media-key commands ourselves.
        playerView.updatesNowPlayingInfoCenter = false
        playerView.setAccessibilityLabel("视频播放器")
        localVideoView.localKeyAction = { [weak self] key in
            guard let self, self.info?.requiresLocalConversion == true else { return false }
            switch key {
            case 49: self.toggleLocalPlayback()
            case 123: self.skip(by: -15)
            case 124: self.skip(by: 15)
            default: return false
            }
            return true
        }
        content.addSubview(playerView)
        let playerBottom = playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        self.playerBottom = playerBottom
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerBottom
        ])
        configureSourceTimeline(in: content)
        localVideoView.translatesAutoresizingMaskIntoConstraints = false
        localVideoView.isHidden = true
        content.addSubview(localVideoView)
        NSLayoutConstraint.activate([
            localVideoView.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            localVideoView.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            localVideoView.topAnchor.constraint(equalTo: playerView.topAnchor),
            localVideoView.bottomAnchor.constraint(equalTo: playerView.bottomAnchor)
        ])
        let overlay = content
        demoLabel.translatesAutoresizingMaskIntoConstraints = false
        demoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        demoLabel.textColor = .white
        demoLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        demoLabel.drawsBackground = true
        demoLabel.isHidden = true
        overlay.addSubview(demoLabel)
        NSLayoutConstraint.activate([
            demoLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 18),
            demoLabel.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 16),
            demoLabel.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -18)
        ])
        captionView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(captionView)
        NSLayoutConstraint.activate([
            captionView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            captionView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -86),
            captionView.widthAnchor.constraint(equalTo: overlay.widthAnchor, multiplier: 0.8),
            captionView.heightAnchor.constraint(equalToConstant: 144)
        ])
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.alignment = .center
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryPlayback)
        retryButton.isHidden = true
        let status = NSStackView(views: [spinner, messageLabel, retryButton])
        status.orientation = .vertical
        status.spacing = 16
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.75)
        ])
        subtitleMenu.target = self
        subtitleMenu.action = #selector(selectSubtitle)
        subtitleMenu.setAccessibilityLabel("选择字幕")
        audioMenu.target = self
        audioMenu.action = #selector(selectAudio)
        audioMenu.setAccessibilityLabel("选择音轨")
        audioMenu.addItem(withTitle: "音轨")
        audioMenu.isEnabled = false
        resetSubtitleMenu()
        let toolbar = NSToolbar(identifier: "LumaPlayerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    private func installMPV(_ info: PlaybackInfo, ticket: UUID) throws {
        let engine = try MPVPlayback()
        self.info = info
        mpv = engine
        mpvTrackSignature = ""
        mpvControlSignature = ""
        playerView.isHidden = true
        localVideoView.isHidden = true
        localControls.isHidden = false
        playerBottom?.constant = -48
        window?.subtitle = "直接播放 · 原画质"
        sourceTimeline.maxValue = max(1, Double(item?.durationTicks ?? 0) / 10_000_000)
        sourceTimeline.isEnabled = (item?.durationTicks ?? 0) > 0
        sourceTimeline.doubleValue = Double(info.startTicks) / 10_000_000
        sourceTime.stringValue = "\(Self.timeText(sourceTimeline.doubleValue)) / \(Self.timeText(sourceTimeline.maxValue))"
        localSpeed.selectItem(withTag: Int(desiredRate * 100))
        localVolume.doubleValue = Double(savedMuted ? 0 : savedVolume)
        let video = engine.view
        video.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(video, positioned: .above, relativeTo: playerView)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            video.topAnchor.constraint(equalTo: playerView.topAnchor),
            video.bottomAnchor.constraint(equalTo: playerView.bottomAnchor)
        ])
        window?.makeFirstResponder(video)
        engine.onKeyDown = { [weak self] key in
            guard let self else { return false }
            switch key {
            case 49: self.toggleLocalPlayback()
            case 123: self.skip(by: -15)
            case 124: self.skip(by: 15)
            default: return false
            }
            return true
        }
        reporter = PlaybackReporter(service: service, info: info)
        installRemoteCommands()
        engine.onReady = { [weak self, weak engine] in
            guard let self, let engine, self.generation == ticket, self.mpv === engine, !self.hasStarted else { return }
            self.hasStarted = true
            self.setMessage("", loading: false)
            self.configureMPVSubtitles()
            self.reporter?.start(positionTicks: self.positionTicks())
            self.reportProgress()
            self.updateMPVState()
        }
        engine.onUpdate = { [weak self, weak engine] in
            guard let self, self.generation == ticket, self.mpv === engine else { return }
            self.updateMPVState()
        }
        engine.onEnded = { [weak self] in
            guard let self, self.generation == ticket else { return }
            let completedItem = self.item
            let shouldContinue = self.preferences.autoplayNext && completedItem?.kind == .episode
            self.stop()
            self.setMessage("播放完毕", loading: false, retry: true)
            if shouldContinue, let completedItem { self.onNextEpisode?(completedItem) }
        }
        engine.onError = { [weak self] message in
            guard let self, self.generation == ticket else { return }
            self.stop()
            self.setMessage(message + " 将从刚才的位置重试。", loading: false, retry: true)
        }
        engine.onWarning = { [weak self] message in
            guard let self, self.generation == ticket else { return }
            self.mpvTrackSignature = ""
            self.refreshMPVTracks()
            guard let window = self.window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = "操作未完成"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: window)
        }
        engine.setVolume(Double(savedVolume))
        engine.setMuted(savedMuted)
        engine.setSpeed(Double(desiredRate))
        do {
            try engine.load(url: info.url, startSeconds: Double(info.startTicks) / 10_000_000,
                            paused: startPaused, defaultSubtitles: preferences.defaultSubtitle)
        } catch {
            engine.view.removeFromSuperview()
            engine.stop()
            mpv = nil
            reporter = nil
            throw error
        }
    }

    private func updateMPVState() {
        guard let mpv else { return }
        if mpv.duration.isFinite, mpv.duration > 0 {
            sourceTimeline.maxValue = mpv.duration
            sourceTimeline.isEnabled = true
        }
        refreshMPVTracks()
        guard hasStarted else { return }
        updateSourceTimeline()
        // A paused seek may produce no further events once its final frame is
        // ready. Include that position so the server receives the final value.
        let pausedPosition = mpv.isPaused ? Int64(mpv.position * 1_000) : 0
        let controls = "\(mpv.isPaused)|\(mpv.isBuffering)|\(mpv.speed)|\(mpv.isMuted)|\(Int(mpv.volume * 100))|\(pausedPosition)"
        let controlsChanged = controls != mpvControlSignature
        if controlsChanged || Date().timeIntervalSince(lastReport) >= 10 {
            mpvControlSignature = controls
            reportProgress()
        }
        if controlsChanged || Date().timeIntervalSince(lastNowPlayingUpdate) >= 1 { updateNowPlaying() }
        let hardware = !mpv.hardwareDecoder.isEmpty && mpv.hardwareDecoder != "no"
        window?.subtitle = mpv.isBuffering ? "正在缓冲…" : (hardware ? "直接播放 · 硬件解码" : "直接播放 · 原画质")
        if mpv.isBuffering && !mpv.isPaused { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
    }

    private func configureMPVSubtitles() {
        guard let mpv else { return }
        refreshMPVTracks()
        if let savedSubtitleKey,
           let index = subtitleChoices.firstIndex(where: { subtitleKey($0) == savedSubtitleKey }) {
            subtitleMenu.selectItem(at: index)
            selectSubtitle()
        } else if preferences.defaultSubtitle {
            if let track = info?.subtitles.first(where: { $0.isDefault }) {
                mpv.addSubtitle(url: track.url, title: track.title)
            } else if !mpv.subtitleTracks.contains(where: { $0.selected }) {
                if let track = mpv.subtitleTracks.first { mpv.selectSubtitle(id: track.id) }
                else if let track = info?.subtitles.first { mpv.addSubtitle(url: track.url, title: track.title) }
            }
        }
    }

    private func refreshMPVTracks() {
        guard let mpv else { return }
        let signature = "tracks|" + mpv.audioTracks.map { "a\($0.id):\($0.title):\($0.selected)" }.joined(separator: "|")
            + mpv.subtitleTracks.map { "s\($0.id):\($0.title):\($0.selected)" }.joined(separator: "|")
        guard signature != mpvTrackSignature else { return }
        mpvTrackSignature = signature
        audioMenu.removeAllItems()
        for track in mpv.audioTracks {
            audioMenu.appendTrackItem(title: track.title, tag: track.id)
            if track.selected { audioMenu.select(audioMenu.lastItem) }
        }
        if audioMenu.numberOfItems == 0 { audioMenu.addItem(withTitle: "无音轨") }
        audioMenu.isEnabled = mpv.audioTracks.count > 1
        resetSubtitleMenu()
        for track in mpv.subtitleTracks {
            subtitleChoices.append(.mpv(track.id))
            subtitleMenu.appendTrackItem(title: track.title)
            if track.selected { subtitleMenu.selectItem(at: subtitleChoices.count - 1) }
        }
        // Emby may expose sidecar subtitles that are absent from the container.
        for track in info?.subtitles ?? [] {
            subtitleChoices.append(.external(track))
            subtitleMenu.appendTrackItem(title: "\(track.title) · 服务器字幕")
        }
        subtitleMenu.isEnabled = subtitleChoices.count > 1
    }

    @objc private func selectAudio() {
        guard let id = audioMenu.selectedItem?.tag else { return }
        mpv?.selectAudio(id: id)
    }

    private func install(_ info: PlaybackInfo, ticket: UUID) {
        self.info = info
        let demoTitle = info.label ?? "演示视频 · Sintel"
        demoLabel.stringValue = demoTitle
        demoLabel.isHidden = !info.isDemo
        window?.subtitle = info.isDemo ? demoTitle : (info.requiresLocalConversion ? "本地兼容播放 · 原画质" : "")
        localControls.isHidden = !info.requiresLocalConversion
        playerBottom?.constant = info.requiresLocalConversion ? -48 : 0
        // AVKit's floating scrubber traps on an indefinite live-HLS time on
        // macOS 27. Use our native AppKit controls for rolling local streams.
        playerView.isHidden = info.requiresLocalConversion
        localVideoView.isHidden = !info.requiresLocalConversion
        localSpeed.selectItem(withTag: Int(desiredRate * 100))
        sourceTimeline.maxValue = max(1, Double(item?.durationTicks ?? 0) / 10_000_000)
        sourceTimeline.isEnabled = (item?.durationTicks ?? 0) > 0
        let asset = AVURLAsset(url: info.url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        player.defaultRate = desiredRate
        player.volume = savedVolume
        player.isMuted = savedMuted
        localVolume.doubleValue = Double(savedMuted ? 0 : savedVolume)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        if info.requiresLocalConversion {
            localVideoView.playerLayer.player = player
            window?.makeFirstResponder(localVideoView)
        } else {
            playerView.player = player
            window?.makeFirstResponder(playerView)
        }
        installRemoteCommands()
        reporter = PlaybackReporter(service: service, info: info)
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] observed, _ in
            let requested = observed.defaultRate
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket, requested.isFinite, requested > 0,
                      abs(self.desiredRate - requested) > 0.001 else { return }
                self.desiredRate = min(4, max(0.25, requested))
                if self.info?.requiresLocalConversion == true, var item = self.item {
                    item.positionTicks = self.positionTicks()
                    self.play(item, preferences: self.preferences, paused: self.player?.timeControlStatus == .paused, presentWindow: false)
                }
            }
        }
        statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                switch observed.status {
                case .readyToPlay: self.startWhenReady(ticket: ticket)
                case .failed: self.failPlayback()
                default: break
                }
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket, self.hasStarted else { return }
                let paused = self.player?.timeControlStatus == .paused
                if self.info?.requiresLocalConversion == true {
                    if self.localPaused && !paused {
                        self.resumeLocalPlayback()
                        return
                    }
                    self.localPaused = paused
                    self.localBridge?.setPaused(paused)
                }
                self.reportProgress()
            }
        }
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                if let error = self.localBridge?.failureDescription {
                    self.stop()
                    self.setMessage(error + " 将从刚才的位置重试。", loading: false, retry: true)
                    return
                }
                self.captionView.text = self.subtitleDocument?.text(at: time.seconds + Double(self.sourceOffsetTicks) / 10_000_000) ?? ""
                if self.hasStarted { self.updateSourceTimeline() }
                if self.hasStarted, Date().timeIntervalSince(self.lastReport) >= 10 { self.reportProgress() }
                if self.hasStarted, Date().timeIntervalSince(self.lastNowPlayingUpdate) >= 1 { self.updateNowPlaying() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                if self.localBridge?.requiresRestartOnResume == true { return }
                let completedItem = self.item
                let shouldContinue = self.preferences.autoplayNext && completedItem?.kind == .episode
                self.stop()
                self.setMessage("播放完毕", loading: false, retry: true)
                if shouldContinue, let completedItem { self.onNextEpisode?(completedItem) }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == ticket else { return }
                self.failPlayback()
            }
        }
        Task { [weak self] in
            let group = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.generation == ticket else { return }
            self.configureSubtitles(group: group, info: info)
        }
    }

    private func startWhenReady(ticket: UUID) {
        guard !hasStarted, !isStarting, let player, let info else { return }
        isStarting = true
        Task { [weak self] in
            if info.requiresLocalConversion {
                // A growing HLS stream otherwise starts at its live edge and
                // skips the first buffered seconds of the requested position.
                let first = player.currentItem?.seekableTimeRanges.first?.timeRangeValue.start ?? .zero
                await player.seek(to: first, toleranceBefore: .zero, toleranceAfter: .zero)
            } else if info.startTicks > 0 {
                let requested = Double(info.startTicks) / 10_000_000
                let duration = player.currentItem?.duration.seconds ?? .nan
                let target = duration.isFinite && duration > 0 ? min(requested, max(0, duration - 1)) : requested
                await player.seek(to: CMTime(seconds: info.isDemo ? 0 : target, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard let self, self.generation == ticket, self.player === player else { return }
            self.isStarting = false
            self.hasStarted = true
            self.setMessage("", loading: false)
            self.reporter?.start(positionTicks: self.positionTicks())
            self.lastReport = Date()
            if !self.startPaused { player.play() }
            self.localPaused = info.requiresLocalConversion && self.startPaused
            self.localBridge?.setPaused(self.startPaused)
            self.reportProgress()
            self.updateSourceTimeline()
            self.updateNowPlaying()
        }
    }

    private func reportProgress() {
        guard hasStarted, mpv != nil || player != nil else { return }
        lastReport = Date()
        reporter?.progress(positionTicks: positionTicks(), isPaused: playbackPaused,
                           isMuted: mpv?.isMuted ?? player?.isMuted ?? false,
                           volume: Int((mpv?.volume ?? Double(player?.volume ?? 1)) * 100))
        updateNowPlaying()
    }

    private var playbackPaused: Bool { mpv?.isPaused ?? (player?.timeControlStatus == .paused) }

    private func setPlaybackPaused(_ paused: Bool) {
        if let mpv { mpv.setPaused(paused) }
        else if paused { player?.pause() }
        else if info?.requiresLocalConversion == true, localPaused { resumeLocalPlayback() }
        else { player?.play() }
    }

    private func positionTicks() -> Int64 {
        guard hasStarted, let seconds = mpv?.position ?? player?.currentTime().seconds, seconds.isFinite, seconds >= 0 else { return lastPositionTicks }
        lastPositionTicks = Int64(min(seconds * 10_000_000 + Double(sourceOffsetTicks), Double(Int64.max - 10_000_000)))
        return lastPositionTicks
    }

    private func failPlayback() {
        if let error = player?.currentItem?.error as NSError? {
            NSLog("Luma playback failure: %@ (%ld)", error.domain, error.code)
        }
        if let event = player?.currentItem?.errorLog()?.events.last {
            NSLog("Luma playback stream failure: %@ (%ld)", event.errorDomain, event.errorStatusCode)
        }
        let wasLocal = info?.requiresLocalConversion == true
        stop()
        setMessage(wasLocal ? "兼容播放已中断，请检查网络后重试。将从刚才的位置继续。" : "此视频暂时无法播放。请确认 Emby 服务器允许转码，然后重试。", loading: false, retry: true)
    }

    private func setMessage(_ text: String, loading: Bool, retry: Bool = false) {
        messageLabel.stringValue = text
        messageLabel.isHidden = text.isEmpty
        retryButton.isHidden = !retry
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func retryPlayback() {
        guard var item else { return }
        // Replaying a completed item should start from its beginning.
        if messageLabel.stringValue == "播放完毕" { item.positionTicks = 0 }
        play(item, preferences: preferences)
    }

    private func resetSubtitleMenu() {
        subtitleChoices = [.off]
        subtitleMenu.removeAllItems()
        subtitleMenu.addItem(withTitle: "字幕：关闭")
        subtitleMenu.isEnabled = false
    }

    private func configureSubtitles(group: AVMediaSelectionGroup?, info: PlaybackInfo) {
        subtitleGroup = group
        resetSubtitleMenu()
        if let group {
            for option in AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options) {
                subtitleChoices.append(.embedded(option))
                subtitleMenu.appendTrackItem(title: option.displayName)
            }
        }
        for track in info.subtitles {
            subtitleChoices.append(.external(track))
            subtitleMenu.appendTrackItem(title: track.title)
        }
        subtitleMenu.isEnabled = subtitleChoices.count > 1
        var selectedIndex = 0
        if preferences.defaultSubtitle {
            if let index = subtitleChoices.firstIndex(where: { choice in
                if case let .external(track) = choice { return track.isDefault }
                return false
            }) { selectedIndex = index }
            else if subtitleChoices.count > 1 { selectedIndex = 1 }
        }
        if let savedSubtitleKey,
           let index = subtitleChoices.firstIndex(where: { subtitleKey($0) == savedSubtitleKey }) {
            selectedIndex = index
        }
        subtitleMenu.selectItem(at: selectedIndex)
        selectSubtitle()
    }

    private func subtitleKey(_ choice: SubtitleChoice) -> String {
        switch choice {
        case .off: return "off"
        case let .external(track): return "external:\(track.index)"
        case let .embedded(option): return "embedded:\(option.extendedLanguageTag ?? ""):\(option.displayName)"
        case let .mpv(id): return "mpv:\(id)"
        }
    }

    @objc private func selectSubtitle() {
        let index = subtitleMenu.indexOfSelectedItem
        guard subtitleChoices.indices.contains(index) else { return }
        subtitleTask?.cancel()
        subtitleGeneration = UUID()
        let subtitleTicket = subtitleGeneration
        let playbackTicket = generation
        subtitleDocument = nil
        captionView.text = ""
        let choice = subtitleChoices[index]
        savedSubtitleKey = subtitleKey(choice)
        if let mpv {
            switch choice {
            case .off: mpv.selectSubtitle(id: nil)
            case let .mpv(id): mpv.selectSubtitle(id: id)
            case let .external(track): mpv.addSubtitle(url: track.url, title: track.title)
            case .embedded: break
            }
            return
        }
        if let subtitleGroup {
            if case let .embedded(option) = choice { player?.currentItem?.select(option, in: subtitleGroup) }
            else { player?.currentItem?.select(nil, in: subtitleGroup) }
        }
        guard case let .external(track) = choice else { return }
        subtitleTask = Task { [weak self] in
            do {
                let document = try await loadSubtitle(from: track.url)
                guard let self, self.generation == playbackTicket, self.subtitleGeneration == subtitleTicket else { return }
                self.subtitleDocument = document
            } catch {
                guard !Task.isCancelled, let self, self.generation == playbackTicket,
                      self.subtitleGeneration == subtitleTicket else { return }
                self.subtitleMenu.selectItem(at: 0)
                self.savedSubtitleKey = "off"
                let alert = NSAlert()
                alert.messageText = "无法载入字幕"
                alert.informativeText = "该字幕无法读取，请选择其他字幕或稍后重试。"
                alert.addButton(withTitle: "好")
                if let window = self.window { await alert.beginSheetModal(for: window) }
            }
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("audio"), .init("subtitles")]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .init("audio"), .init("subtitles")]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard ["subtitles", "audio"].contains(itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = itemIdentifier.rawValue == "audio" ? "音轨" : "字幕"
        item.view = itemIdentifier.rawValue == "audio" ? audioMenu : subtitleMenu
        return item
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        addRemoteTarget(center.playCommand) { controller, _ in controller.setPlaybackPaused(false) }
        addRemoteTarget(center.pauseCommand) { controller, _ in controller.setPlaybackPaused(true) }
        addRemoteTarget(center.togglePlayPauseCommand) { controller, _ in
            controller.setPlaybackPaused(!controller.playbackPaused)
        }
        addRemoteTarget(center.changePlaybackPositionCommand) { controller, event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return }
            controller.seekSource(to: position)
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        addRemoteTarget(center.skipForwardCommand) { controller, event in
            controller.skip(by: (event as? MPSkipIntervalCommandEvent)?.interval ?? 15)
        }
        addRemoteTarget(center.skipBackwardCommand) { controller, event in
            controller.skip(by: -((event as? MPSkipIntervalCommandEvent)?.interval ?? 15))
        }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand,
                                 action: @escaping @MainActor (PlayerWindowController, MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self, event)
            }
            return .success
        }
        remoteTargets.append((command, target))
    }

    private func skip(by interval: TimeInterval) {
        guard player != nil || mpv != nil else { return }
        seekSource(to: Double(positionTicks()) / 10_000_000 + interval)
    }

    private func configureSourceTimeline(in content: NSView) {
        localPlayPause.bezelStyle = .rounded
        localPlayPause.target = self
        localPlayPause.action = #selector(toggleLocalPlayback)
        localPlayPause.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        localPlayPause.setAccessibilityLabel("暂停")
        let back = UI.button("", symbol: "gobackward.15", target: self, action: #selector(skipBackward))
        let forward = UI.button("", symbol: "goforward.15", target: self, action: #selector(skipForward))
        back.setAccessibilityLabel("后退 15 秒")
        forward.setAccessibilityLabel("前进 15 秒")
        sourceTimeline.target = self
        sourceTimeline.action = #selector(sourceSeekChanged)
        sourceTimeline.isContinuous = false
        sourceTimeline.setAccessibilityLabel("整片播放进度")
        sourceTime.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sourceTime.textColor = .secondaryLabelColor
        sourceTime.setContentHuggingPriority(.required, for: .horizontal)
        localVolume.target = self
        localVolume.action = #selector(localVolumeChanged)
        localVolume.setAccessibilityLabel("音量")
        localVolume.widthAnchor.constraint(equalToConstant: 64).isActive = true
        for rate in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            localSpeed.addItem(withTitle: "\(rate.formatted())×")
            localSpeed.lastItem?.tag = Int(rate * 100)
        }
        localSpeed.target = self
        localSpeed.action = #selector(localSpeedChanged)
        localSpeed.setAccessibilityLabel("播放速度")
        localControls.orientation = .horizontal
        localControls.alignment = .centerY
        localControls.spacing = 10
        [localPlayPause, back, sourceTimeline, forward, sourceTime, localSpeed, localVolume].forEach { localControls.addArrangedSubview($0) }
        localControls.translatesAutoresizingMaskIntoConstraints = false
        localControls.isHidden = true
        content.addSubview(localControls)
        NSLayoutConstraint.activate([
            localControls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            localControls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            localControls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            localControls.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func updateSourceTimeline() {
        guard info?.requiresLocalConversion == true || mpv != nil else { return }
        let elapsed = Double(positionTicks()) / 10_000_000
        // Leave the thumb under the user's control during a drag.
        if NSApp.currentEvent?.type != .leftMouseDragged { sourceTimeline.doubleValue = elapsed }
        sourceTime.stringValue = "\(Self.timeText(elapsed)) / \(Self.timeText(sourceTimeline.maxValue))"
        let paused = playbackPaused
        localPlayPause.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        localPlayPause.setAccessibilityLabel(paused ? "播放" : "暂停")
        if NSApp.currentEvent?.type != .leftMouseDragged {
            if let mpv { localVolume.doubleValue = mpv.isMuted ? 0 : mpv.volume }
            else if let player { localVolume.doubleValue = Double(player.isMuted ? 0 : player.volume) }
        }
    }

    private static func timeText(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    @objc private func sourceSeekChanged() { seekSource(to: sourceTimeline.doubleValue) }
    @objc private func skipBackward() { skip(by: -15) }
    @objc private func skipForward() { skip(by: 15) }
    @objc private func toggleLocalPlayback() {
        guard player != nil || mpv != nil else { return }
        setPlaybackPaused(!playbackPaused)
        updateSourceTimeline()
    }
    private func resumeLocalPlayback() {
        guard var item else { return }
        item.positionTicks = positionTicks()
        play(item, preferences: preferences, presentWindow: false)
    }
    @objc private func localSpeedChanged() {
        guard let tag = localSpeed.selectedItem?.tag else { return }
        if let mpv { desiredRate = Float(tag) / 100; mpv.setSpeed(Double(desiredRate)) }
        else { player?.defaultRate = Float(tag) / 100 }
    }
    @objc private func localVolumeChanged() {
        if let mpv {
            mpv.setVolume(localVolume.doubleValue)
            mpv.setMuted(localVolume.doubleValue == 0)
        } else {
            player?.volume = Float(localVolume.doubleValue)
            player?.isMuted = localVolume.doubleValue == 0
        }
        reportProgress()
    }

    private func seekSource(to seconds: Double) {
        guard seconds.isFinite, var item else { return }
        let duration = Double(item.durationTicks) / 10_000_000
        let target = max(0, duration > 0 ? min(seconds, max(0, duration - 1)) : seconds)
        if let mpv {
            mpv.seek(seconds: target)
            lastReport = .distantPast
            return
        }
        guard let player else { return }
        if info?.requiresLocalConversion == true {
            let localTime = target - Double(sourceOffsetTicks) / 10_000_000
            let available = player.currentItem?.seekableTimeRanges.contains { range in
                let time = range.timeRangeValue
                return localTime >= time.start.seconds && localTime <= CMTimeRangeGetEnd(time).seconds
            } ?? false
            if available {
                player.seek(to: CMTime(seconds: localTime, preferredTimescale: 600))
            } else {
                item.positionTicks = Int64(target * 10_000_000)
                play(item, preferences: preferences, paused: player.timeControlStatus == .paused, presentWindow: false)
            }
        } else {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
    }

    private func updateNowPlaying() {
        guard let item, player != nil || mpv != nil else { return }
        lastNowPlayingUpdate = Date()
        let rate = mpv.map { $0.isPaused || $0.isBuffering ? 0 : $0.speed } ?? Double(player?.rate ?? 0)
        let defaultRate = mpv?.speed ?? Double(player?.defaultRate ?? 1)
        var metadata: [String: Any] = [
            MPMediaItemPropertyTitle: info?.isDemo == true ? info?.label ?? "演示视频 · Sintel" : item.title,
            MPMediaItemPropertyArtist: item.seriesTitle ?? "Luma",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: item.id,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionTicks()) / 10_000_000,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: defaultRate
        ]
        if let duration = mpv?.duration, duration.isFinite, duration > 0 {
            metadata[MPMediaItemPropertyPlaybackDuration] = duration
        } else if info?.requiresLocalConversion == true, item.durationTicks > 0 {
            metadata[MPMediaItemPropertyPlaybackDuration] = Double(item.durationTicks) / 10_000_000
        } else if let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            metadata[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = metadata
        center.playbackState = playbackPaused ? .paused : .playing
    }
}

private final class NativeVideoView: NSView {
    let playerLayer = AVPlayerLayer()
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        setAccessibilityLabel("视频播放器")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    var localKeyAction: ((UInt16) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty || localKeyAction?(event.keyCode) != true {
            super.keyDown(with: event)
        }
    }
}

private enum SubtitleError: Error { case unavailable }

// The nonisolated async function performs network iteration and parsing off the UI actor.
private func loadSubtitle(from url: URL) async throws -> SubtitleDocument {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(from: url)
    guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { throw SubtitleError.unavailable }
    var data = Data()
    for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < 4 * 1_024 * 1_024 else { throw SubtitleError.unavailable }
        data.append(byte)
    }
    guard let source = String(data: data, encoding: .utf8) else { throw SubtitleError.unavailable }
    return SubtitleDocument(webVTT: source)
}

/// One chain per playback session keeps start → progress → stop ordered across suspension points.
@MainActor
final class PlaybackReporter {
    private let info: PlaybackInfo
    private let sendReport: @Sendable (PlaybackEvent) async -> Void
    private let cancelSession: @Sendable (String) async -> Void
    private var tail: Task<Void, Never>?
    private var didStart = false
    private var didFinish = false
    private var pendingProgress: PlaybackEvent?
    private var progressInFlight = false

    convenience init(service: MediaService, info: PlaybackInfo) {
        self.init(info: info, report: { try? await service.report(event: $0) },
                  cancel: { try? await service.cancelPlayback(playSessionID: $0) })
    }

    init(info: PlaybackInfo, report: @escaping @Sendable (PlaybackEvent) async -> Void,
         cancel: @escaping @Sendable (String) async -> Void) {
        self.info = info
        sendReport = report
        cancelSession = cancel
    }

    func start(positionTicks: Int64) {
        guard !didStart, !didFinish else { return }
        didStart = true
        enqueue(event("start", positionTicks: positionTicks))
    }

    func progress(positionTicks: Int64, isPaused: Bool, isMuted: Bool, volume: Int) {
        guard didStart, !didFinish else { return }
        pendingProgress = event("progress", positionTicks: positionTicks, isPaused: isPaused, isMuted: isMuted, volume: volume)
        guard !progressInFlight else { return }
        progressInFlight = true
        let previous = tail, sendReport = sendReport
        tail = Task {
            await previous?.value
            // A slow request may receive newer positions (or a pause) while it
            // is suspended. Drain the latest state before releasing the chain.
            while let pendingProgress = self.pendingProgress {
                self.pendingProgress = nil
                await sendReport(pendingProgress)
            }
            self.progressInFlight = false
        }
    }

    @discardableResult
    func finish(positionTicks: Int64, completion: (() -> Void)?) -> Task<Void, Never>? {
        guard !didFinish else { return tail }
        didFinish = true
        let stopEvent = didStart ? event("stop", positionTicks: positionTicks) : nil
        let previous = tail, sendReport = sendReport, cancelSession = cancelSession, sessionID = info.playSessionID
        tail = Task {
            await previous?.value
            if let stopEvent { await sendReport(stopEvent) }
            await cancelSession(sessionID)
            completion?()
        }
        return tail
    }

    private func enqueue(_ event: PlaybackEvent) {
        let previous = tail, sendReport = sendReport
        tail = Task {
            await previous?.value
            await sendReport(event)
        }
    }

    private func event(_ type: String, positionTicks: Int64, isPaused: Bool? = nil,
                       isMuted: Bool? = nil, volume: Int? = nil) -> PlaybackEvent {
        PlaybackEvent(type: type, itemID: info.itemID, mediaSourceID: info.mediaSourceID,
                      playSessionID: info.playSessionID, playMethod: info.playMethod,
                      positionTicks: max(0, positionTicks), isPaused: isPaused, isMuted: isMuted,
                      volumeLevel: volume.map { min(100, max(0, $0)) })
    }
}

private final class CaptionView: NSView {
    var text = "" { didSet { if oldValue != text { needsDisplay = true; setAccessibilityValue(text) } } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("字幕")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(28, max(18, bounds.width / 28)), weight: .medium),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.boundingRect(with: NSSize(width: max(0, bounds.width - 28), height: bounds.height - 20),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let box = NSRect(x: (bounds.width - size.width) / 2 - 12, y: bounds.height - size.height - 18,
                         width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.64).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        string.draw(in: box.insetBy(dx: 12, dy: 6))
    }
}
