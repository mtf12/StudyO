import AppKit
import Combine

extension NSTouchBarItem.Identifier {
    static let studyoPlay = NSTouchBarItem.Identifier("com.studyo.player.touchbar.play")
    static let studyoScrub = NSTouchBarItem.Identifier("com.studyo.player.touchbar.scrub")
    static let studyoTime = NSTouchBarItem.Identifier("com.studyo.player.touchbar.time")
    static let studyoWave = NSTouchBarItem.Identifier("com.studyo.player.touchbar.wave")
    static let studyoSpeeds = NSTouchBarItem.Identifier("com.studyo.player.touchbar.speeds")
}

/// Touch Bar: play/pause button, a strip of video frames you can drag on to seek, and the time.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let shared = TouchBarController()

    private var bag = Set<AnyCancellable>()
    private var playButton: NSButton?
    private var strip: ScrubStripView?
    private var timeLabel: NSTextField?
    private var playItem: NSPopoverTouchBarItem?
    private var speedControl: NSSegmentedControl?
    private let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]

    private(set) lazy var bar: NSTouchBar = {
        let b = NSTouchBar()
        b.delegate = self
        b.defaultItemIdentifiers = [.studyoPlay, .studyoScrub, .studyoTime, .studyoWave]
        return b
    }()

    func install() {
        let player = PlayerModel.shared
        player.$isPlaying.receive(on: RunLoop.main).sink { [weak self] playing in
            self?.playButton?.image = Self.symbol(playing ? "pause.fill" : "play.fill")
        }.store(in: &bag)
        player.clock.$timeMs.receive(on: RunLoop.main).sink { [weak self] time in
            guard let self else { return }
            let length = player.lengthMs
            self.strip?.progress = length > 0 ? CGFloat(time / length) : 0
            self.timeLabel?.stringValue = formatTime(time)
        }.store(in: &bag)
        player.$rate.receive(on: RunLoop.main).sink { [weak self] rate in
            guard let self else { return }
            self.speedControl?.selectedSegment = self.speeds.firstIndex(of: rate) ?? -1
        }.store(in: &bag)
        player.$thumbs.receive(on: RunLoop.main).sink { [weak self] thumbs in
            self?.strip?.thumbs = thumbs
        }.store(in: &bag)
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    @objc private func togglePlay() { PlayerModel.shared.togglePlay() }

    /// Holding the play button expands the Touch Bar into the list of playback speeds.
    @objc private func playHeld(_ recognizer: NSPressGestureRecognizer) {
        if recognizer.state == .began { playItem?.showPopover(nil) }
    }

    @objc private func speedPicked(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < speeds.count else { return }
        PlayerModel.shared.setRate(speeds[sender.selectedSegment])
        playItem?.dismissPopover(nil)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        dbg("touchbar makeItem \(identifier.rawValue)")
        let player = PlayerModel.shared
        if identifier == .studyoPlay {
            // Tap: play/pause. Press and hold: the bar expands to show the playback speeds.
            let popover = NSPopoverTouchBarItem(identifier: identifier)
            let button = NSButton(image: Self.symbol(player.isPlaying ? "pause.fill" : "play.fill"),
                                  target: self, action: #selector(togglePlay))
            button.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let hold = NSPressGestureRecognizer(target: self, action: #selector(playHeld(_:)))
            hold.allowedTouchTypes = [.direct]
            hold.minimumPressDuration = 0.35
            button.addGestureRecognizer(hold)
            playButton = button
            popover.collapsedRepresentation = button
            popover.showsCloseButton = true
            let speedBar = NSTouchBar()
            speedBar.delegate = self
            speedBar.defaultItemIdentifiers = [.studyoSpeeds]
            popover.popoverTouchBar = speedBar
            playItem = popover
            return popover
        }
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case .studyoSpeeds:
            let control = NSSegmentedControl(labels: speeds.map { String(format: "%g×", $0) },
                                             trackingMode: .selectOne,
                                             target: self, action: #selector(speedPicked(_:)))
            control.selectedSegment = speeds.firstIndex(of: player.rate) ?? -1
            control.segmentDistribution = .fillEqually
            control.widthAnchor.constraint(equalToConstant: 580).isActive = true
            speedControl = control
            item.view = control
        case .studyoWave:
            // The meter itself pushes new heights into this view every frame.
            let view = MeterView(barWidth: 2, insetY: 6)
            view.widthAnchor.constraint(equalToConstant: 28).isActive = true
            item.view = view
        case .studyoScrub:
            let view = ScrubStripView()
            view.thumbs = player.thumbs
            view.onSeek = { fraction in
                let p = PlayerModel.shared
                if p.lengthMs > 0 { p.seek(toMs: Double(fraction) * p.lengthMs) }
            }
            strip = view
            item.view = view
        case .studyoTime:
            let label = NSTextField(labelWithString: formatTime(player.timeMs))
            label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true
            timeLabel = label
            item.view = label
        default:
            return nil
        }
        return item
    }
}

/// The frame strip. Touch or drag anywhere on it to jump to that part of the video.
final class ScrubStripView: NSView {
    var thumbs: [CGImage?] = [] { didSet { needsDisplay = true } }
    var progress: CGFloat = 0 { didSet { if abs(progress - oldValue) > 0.001 { needsDisplay = true } } }
    var onSeek: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        allowedTouchTypes = [.direct]
    }
    required init?(coder: NSCoder) { fatalError() }

    private lazy var widthConstraint: NSLayoutConstraint = {
        let c = widthAnchor.constraint(equalToConstant: 470)
        c.isActive = true
        return c
    }()

    private var barObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _ = widthConstraint
        guard window != nil else { return }
        // Once the Touch Bar has laid out, stretch over all the space the other items leave free,
        // and again whenever the bar itself changes size (e.g. the Control Strip is expanded).
        DispatchQueue.main.async { [weak self] in
            guard let self, let barView = self.superview?.superview else { return }
            self.fillFreeSpace()
            barView.postsFrameChangedNotifications = true
            if let old = self.barObserver { NotificationCenter.default.removeObserver(old) }
            self.barObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: barView, queue: .main) { [weak self] _ in
                self?.fillFreeSpace()
            }
        }
    }

    private func fillFreeSpace() {
        guard let container = superview, let barView = container.superview else { return }
        let others = barView.subviews.filter { $0 !== container && !$0.isHidden }
        let gap: CGFloat = 8
        let free = barView.bounds.width - others.reduce(0) { $0 + $1.frame.width } - gap * CGFloat(others.count)
        let target = max(200, free.rounded(.down))
        if abs(widthConstraint.constant - target) > 1 {
            widthConstraint.constant = target
            dbg("strip width -> \(target) (bar \(barView.bounds.width))")
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        dbg("strip draw bounds=\(b) thumbs=\(thumbs.compactMap { $0 }.count)/\(thumbs.count) window=\(window != nil)")
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: b, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor(white: 0.16, alpha: 1).cgColor)
        ctx.fill(b)

        if !thumbs.isEmpty {
            let cell = b.width / CGFloat(thumbs.count)
            for (i, thumb) in thumbs.enumerated() {
                guard let thumb else { continue }
                let slot = CGRect(x: CGFloat(i) * cell, y: 0, width: cell, height: b.height)
                // Aspect-fill the slot.
                let scale = max(slot.width / CGFloat(thumb.width), slot.height / CGFloat(thumb.height))
                let w = CGFloat(thumb.width) * scale, h = CGFloat(thumb.height) * scale
                ctx.saveGState()
                ctx.clip(to: slot)
                ctx.draw(thumb, in: CGRect(x: slot.midX - w / 2, y: slot.midY - h / 2, width: w, height: h))
                ctx.restoreGState()
            }
        }
        // Dim the part not played yet, then draw the playhead.
        let x = max(0, min(progress, 1)) * b.width
        ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.fill(CGRect(x: x, y: 0, width: b.width - x, height: b.height))
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: max(0, min(x - 1.5, b.width - 3)), y: 0, width: 3, height: b.height))
    }

    private func handle(_ event: NSEvent) {
        guard let touch = event.touches(matching: .touching, in: self).first, bounds.width > 0 else { return }
        let fraction = max(0, min(touch.location(in: self).x / bounds.width, 1))
        progress = fraction
        onSeek?(fraction)
    }

    override func touchesBegan(with event: NSEvent) { handle(event) }
    override func touchesMoved(with event: NSEvent) { handle(event) }
}

/// Debug log line, only in `./build.sh --selftest` builds.
func dbg(_ text: @autoclosure () -> String) {
    #if SELFTEST
    FileHandle.standardError.write(Data(("[studyo] " + text() + "\n").utf8))
    #endif
}
