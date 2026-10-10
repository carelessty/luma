import AppKit

enum UI {
    static func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading }
        return b
    }
    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = vertical ? .vertical : .horizontal
        s.alignment = vertical ? .leading : .centerY
        s.spacing = spacing
        return s
    }
    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class ArtworkView: NSView {
    private var task: Task<Void, Never>?
    private let picture = CALayer()
    private let placeholder = NSImageView()
    var cornerRadius: CGFloat = 8 { didSet { layer?.cornerRadius = cornerRadius } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        picture.contentsGravity = .resizeAspectFill
        layer?.addSublayer(picture)
        placeholder.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor), placeholder.widthAnchor.constraint(equalToConstant: 30), placeholder.heightAnchor.constraint(equalToConstant: 30)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); picture.frame = bounds; CATransaction.commit() }
    func setImage(_ url: URL?, pixels: Int = 800) {
        task?.cancel()
        picture.contents = nil
        placeholder.isHidden = false
        guard let url else { return }
        task = Task { [weak self] in
            let image = await ImagePipeline.shared.image(for: url, maxPixelSize: pixels)
            guard !Task.isCancelled, let self, let image else { return }
            self.picture.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            self.placeholder.isHidden = true
        }
    }
    deinit { task?.cancel() }
}

private final class HeroShadeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        gradient.colors = [NSColor.black.withAlphaComponent(0.85).cgColor, NSColor.black.withAlphaComponent(0.48).cgColor, NSColor.clear.cgColor]
        gradient.locations = [0, 0.48, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        return gradient
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class HeroView: NSView {
    private let artwork = ArtworkView()
    private let titleLabel = UI.label(size: 34, weight: .bold, color: .white)
    private let metadata = UI.label(size: 13, weight: .medium, color: .init(white: 1, alpha: 0.78))
    private let summary = UI.label(size: 13, color: .init(white: 1, alpha: 0.85))
    private let eyebrow = UI.label("为此刻，选一部好电影", size: 12, weight: .semibold, color: .init(white: 1, alpha: 0.8))
    private var item: MediaItem?
    var onPlay: ((MediaItem) -> Void)?
    var onDetail: ((MediaItem) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        artwork.cornerRadius = 0
        UI.pin(artwork, to: self)
        // AppKit orders view-backed layers itself. A sibling view keeps the
        // contrast shade above the artwork instead of underneath its layer.
        UI.pin(HeroShadeView(), to: self)
        titleLabel.maximumNumberOfLines = 2
        summary.maximumNumberOfLines = 3
        summary.lineBreakMode = .byWordWrapping
        summary.cell?.wraps = true
        summary.cell?.isScrollable = false
        let play = UI.button("播放", symbol: "play.fill", target: self, action: #selector(playPressed))
        play.bezelColor = .controlAccentColor
        play.controlSize = .large
        let detail = UI.button("影片详情", symbol: "info.circle", target: self, action: #selector(detailPressed))
        detail.controlSize = .large
        let buttons = UI.stack([play, detail], vertical: false)
        let actions: NSView
        if #available(macOS 26.0, *) {
            // Use AppKit's actual glass controls over artwork. The container
            // batches their rendering while retaining native focus and clicks.
            for button in [play, detail] {
                button.bezelStyle = .glass
                button.controlSize = .extraLarge
            }
            play.tintProminence = .primary
            detail.tintProminence = .none
            let glass = NSGlassEffectContainerView()
            glass.contentView = buttons
            actions = glass
        } else {
            actions = buttons
        }
        let texts = UI.stack([eyebrow, titleLabel, metadata, summary, actions], spacing: 13)
        texts.setCustomSpacing(8, after: titleLabel)
        texts.setCustomSpacing(10, after: eyebrow)
        texts.setCustomSpacing(9, after: summary)
        texts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(texts)
        let preferredWidth = texts.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.57)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30), texts.centerYAnchor.constraint(equalTo: centerYAnchor), preferredWidth, texts.widthAnchor.constraint(lessThanOrEqualToConstant: 560), summary.widthAnchor.constraint(equalTo: texts.widthAnchor), titleLabel.widthAnchor.constraint(equalTo: texts.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ item: MediaItem, demo: Bool) {
        self.item = item
        titleLabel.stringValue = item.title
        metadata.stringValue = item.metadataText
        summary.stringValue = item.overview
        eyebrow.stringValue = demo ? "精选预览 · 虚构影片" : "从你的资料库，发现好故事"
        artwork.setImage(item.backdropURL ?? item.imageURL, pixels: 1800)
    }
    @objc private func playPressed() { if let item { onPlay?(item) } }
    @objc private func detailPressed() { if let item { onDetail?(item) } }
}

extension MediaItem {
    var metadataText: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if durationTicks > 0 { parts.append(durationTicks < 600_000_000 ? "不到 1 分钟" : "\(Int(durationTicks / 600_000_000)) 分钟") }
        if let rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        parts.append(contentsOf: genres.prefix(2))
        return parts.joined(separator: "  ·  ")
    }
    var shortMetadata: String {
        var parts = [String]()
        if let year { parts.append(String(year)) }
        if let rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: " · ")
    }
}

final class MediaCardView: NSView {
    var onActivate: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onActivate?(); return onActivate != nil }
}

final class MediaCard: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MediaCard")
    let artwork = ArtworkView()
    private let name = UI.label(size: 13, weight: .semibold)
    private let subtitle = UI.label(size: 11, color: .secondaryLabelColor)
    private let progress = NSProgressIndicator()
    private let heart = NSImageView()
    private var item: MediaItem?
    var onOpen: ((MediaItem) -> Void)?
    var onPlay: ((MediaItem) -> Void)?
    var onFavorite: ((MediaItem) -> Void)?
    override func loadView() {
        let cardView = MediaCardView()
        cardView.onActivate = { [weak self] in self?.openItem() }
        view = cardView
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        let stack = UI.stack([artwork, name, subtitle], spacing: 6)
        UI.pin(stack, to: view, inset: 3)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([artwork.widthAnchor.constraint(equalTo: stack.widthAnchor), name.widthAnchor.constraint(equalTo: stack.widthAnchor), subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        artwork.setContentHuggingPriority(.defaultLow, for: .vertical)
        name.setContentHuggingPriority(.required, for: .vertical)
        subtitle.setContentHuggingPriority(.required, for: .vertical)
        progress.isIndeterminate = false
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.translatesAutoresizingMaskIntoConstraints = false
        artwork.addSubview(progress)
        NSLayoutConstraint.activate([progress.leadingAnchor.constraint(equalTo: artwork.leadingAnchor, constant: 10), progress.trailingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: -10), progress.bottomAnchor.constraint(equalTo: artwork.bottomAnchor, constant: -8)])
        heart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "已收藏")
        heart.contentTintColor = .white
        heart.shadow = NSShadow()
        heart.translatesAutoresizingMaskIntoConstraints = false
        artwork.addSubview(heart)
        NSLayoutConstraint.activate([heart.trailingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: -9), heart.topAnchor.constraint(equalTo: artwork.topAnchor, constant: 9), heart.widthAnchor.constraint(equalToConstant: 16), heart.heightAnchor.constraint(equalToConstant: 16)])
        let click = NSClickGestureRecognizer(target: self, action: #selector(openItem))
        click.numberOfClicksRequired = 2
        view.addGestureRecognizer(click)
    }
    override var isSelected: Bool { didSet { view.layer?.borderWidth = isSelected ? 2 : 0; view.layer?.borderColor = NSColor.controlAccentColor.cgColor } }
    func configure(_ item: MediaItem, landscape: Bool = false) {
        self.item = item
        name.stringValue = item.title
        subtitle.stringValue = landscape && item.positionTicks > 0 ? (item.positionTicks < 600_000_000 ? "已观看 \(Int(item.positionTicks / 10_000_000)) 秒" : "已观看 \(Int(item.positionTicks / 600_000_000)) 分钟") : item.shortMetadata
        artwork.setImage(landscape ? (item.backdropURL ?? item.imageURL) : item.imageURL, pixels: landscape ? 700 : 500)
        progress.doubleValue = item.durationTicks > 0 ? min(1, Double(item.positionTicks) / Double(item.durationTicks)) : 0
        progress.isHidden = item.positionTicks <= 0
        heart.isHidden = !item.isFavorite
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("\(item.title)，\(subtitle.stringValue)")
        view.setAccessibilityRole(.button)
        view.setAccessibilityHelp("双击查看详情，回车打开，空格播放")
        view.toolTip = item.title
        let menu = NSMenu()
        for (title, selector) in [("播放", #selector(playItem)), ("显示详情", #selector(openItem)), (item.isFavorite ? "取消收藏" : "加入收藏", #selector(favoriteItem))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        view.menu = menu
    }
    @objc private func openItem() { if let item { onOpen?(item) } }
    @objc private func playItem() { if let item { onPlay?(item) } }
    @objc private func favoriteItem() { if let item { onFavorite?(item) } }
}

final class MediaCollectionView: NSCollectionView {
    var onOpenSelection: ((Bool) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onOpenSelection?(event.keyCode == 49) }
        else { super.keyDown(with: event) }
    }
}

final class MediaScrollView: SmoothScrollView {
    var forwardsVerticalScrolling = false
    private var verticalGesture: Bool?

    override func scrollWheel(with event: NSEvent) {
        guard forwardsVerticalScrolling, let parent = verticalScrollAncestor else {
            super.scrollWheel(with: event)
            return
        }

        let phased = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if !phased || event.phase.contains(.mayBegin) || event.phase.contains(.began) { verticalGesture = nil }
        if verticalGesture == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            // Keep trackpad gestures on their initial axis, including momentum.
            // Shift-wheel remains a native way to browse a horizontal shelf.
            verticalGesture = !event.modifierFlags.contains(.shift) && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        }
        if verticalGesture == true { parent.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }

        if !phased || event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            verticalGesture = nil
        }
    }

    private var verticalScrollAncestor: NSScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller { return scroll }
            ancestor = view.superview
        }
        return nil
    }
}

final class MediaGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    let collection = MediaCollectionView()
    let scroll = MediaScrollView()
    private var lastLayoutSize = NSSize.zero
    var items: [MediaItem] = []
    var landscape = false
    var horizontal = false
    var onOpen: ((MediaItem) -> Void)?
    var onPlay: ((MediaItem) -> Void)?
    var onFavorite: ((MediaItem) -> Void)?
    override func loadView() {
        view = NSView()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = horizontal ? .horizontal : .vertical
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 22
        layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(MediaCard.self, forItemWithIdentifier: MediaCard.identifier)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = !horizontal
        scroll.hasHorizontalScroller = horizontal
        scroll.forwardsVerticalScrolling = horizontal
        scroll.verticalScrollElasticity = horizontal ? .none : .automatic
        scroll.horizontalScrollElasticity = horizontal ? .automatic : .none
        scroll.autohidesScrollers = true
        scroll.documentView = collection
        UI.pin(scroll, to: view)
        collection.onOpenSelection = { [weak self] play in
            guard let self, let index = self.collection.selectionIndexPaths.first?.item, self.items.indices.contains(index) else { return }
            if play { self.onPlay?(self.items[index]) } else { self.onOpen?(self.items[index]) }
        }
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let size = scroll.contentSize
        guard size != lastLayoutSize else { return }
        lastLayoutSize = size
        collection.collectionViewLayout?.invalidateLayout()
    }
    func setItems(_ items: [MediaItem]) { self.items = items; collection.reloadData() }
    func updateFavorite(id: String, value: Bool, remove: Bool = false) {
        let matches = items.indices.filter { items[$0].id == id }
        guard !matches.isEmpty else { return }
        let selectedIDs = Set(collection.selectionIndexPaths.compactMap { path in
            items.indices.contains(path.item) ? items[path.item].id : nil
        })
        let paths = Set(matches.map { IndexPath(item: $0, section: 0) })
        if remove {
            for index in matches.reversed() { items.remove(at: index) }
            collection.deleteItems(at: paths)
        } else {
            for index in matches { items[index].isFavorite = value }
            // Only redraw changed cards; keep the current scroll position and
            // keyboard selection instead of rebuilding the entire page.
            collection.reloadItems(at: paths)
        }
        collection.selectionIndexPaths = Set(items.indices.compactMap { index in
            selectedIDs.contains(items[index].id) ? IndexPath(item: index, section: 0) : nil
        })
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let card = collectionView.makeItem(withIdentifier: MediaCard.identifier, for: indexPath) as! MediaCard
        card.configure(items[indexPath.item], landscape: landscape)
        card.onOpen = onOpen; card.onPlay = onPlay; card.onFavorite = onFavorite
        return card
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        if horizontal { return NSSize(width: landscape ? 260 : 166, height: landscape ? 187 : 292) }
        let width = max(300, scroll.contentSize.width)
        let columns = max(2, Int((width + 16) / 170))
        let cardWidth = floor((width - CGFloat(columns - 1) * 16 - 2) / CGFloat(columns))
        return NSSize(width: cardWidth, height: cardWidth * 1.45 + 48)
    }
}
