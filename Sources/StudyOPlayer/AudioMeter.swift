import AppKit
import QuartzCore
import SwiftUI

/// Drives the little equaliser: six bars that rise and fall with the sound.
///
/// How it stays accurate and smooth:
/// - The engine reports the loudness of each block of sound as it is decoded, which is a little
///   before that block reaches the speakers. Every reading is timestamped, and the bars show the
///   reading from `outputLatency` ago, so they move with what you hear rather than ahead of it.
/// - Loudness is turned into decibels against a slowly adapting ceiling, so quiet passages still
///   move and loud ones do not stay pinned at the top. Sudden hits get a short extra push.
/// - Each bar follows its target on a critically damped spring (fast rise, softer fall), which
///   gives fluid motion with no jitter at any frame rate. The bars read the sound a few
///   milliseconds apart, so movement ripples out from the centre instead of moving in lockstep.
///
/// Cost: one display-synchronised callback (capped at 60 Hz) that updates a few CALayers directly,
/// with no SwiftUI re-rendering. It pauses completely while nothing is playing.
final class AudioMeter: NSObject {
    static let shared = AudioMeter()
    static let barCount = 6 // 6 أعمدة متناسقة ومحندقة

    /// How far the engine's level reading runs ahead of the sound coming out of the speakers.
    /// Measured with a test tone (`./build.sh --selftest`, STUDYO_SELFTEST_AUDIO): readings lead the
    /// engine's playback clock by 60 ms on average (±50 ms, from the way blocks are handed over).
    static let outputLatency: CFTimeInterval = {
        #if SELFTEST
        if let v = ProcessInfo.processInfo.environment["STUDYO_METER_LATENCY"].flatMap(Double.init) { return v }
        #endif
        return 0.06
    }()

    /// Heights shown right now, 0...1.
    private(set) var bars: [CGFloat] = Array(repeating: 0, count: barCount)
    private var velocity: [CGFloat] = Array(repeating: 0, count: barCount)

    // Gains متوازنة عشان تديني الشكل الجميل والمحندق
    private let gains: [CGFloat] = [0.6, 0.8, 1.0, 1.0, 0.8, 0.6]
    /// Each bar listens this much later than the newest sound, so motion spreads from the centre.
    private let lags: [CFTimeInterval] = [0.10, 0.045, 0.0, 0.02, 0.065, 0.12]
    /// Slow, small variation so a long steady note still looks alive.
    private let rippleSpeeds: [Double] = [4.5, 6.0, 4.0, 6.5, 5.0, 5.5]

    // Recent readings (time, peak), newest at `head`. 256 entries cover over 4 s at 60 Hz.
    private static let historySize = 256
    private var times = [CFTimeInterval](repeating: 0, count: historySize)
    private var levels = [Float](repeating: 0, count: historySize)
    private var head = -1

    private var ceilingDb: Float = -30
    private var slowLevel: CGFloat = 0
    private var clock: Double = 0
    private var lastStep: CFTimeInterval = 0
    private var link: CADisplayLink?
    private let views = NSHashTable<MeterView>.weakObjects()

    /// Starts the display-synchronised updates (call once the main window exists).
    func start() {
        guard link == nil else { return }
        let l = PlayerModel.shared.videoView.displayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
        // A window coming back into view (unhidden, uncovered) may need the bars again.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.wake() }
        wake()
    }

    /// Resumes updates after playback starts, stops, or the sound is muted.
    func wake() {
        guard let link, link.isPaused else { return }
        lastStep = 0
        link.isPaused = false
    }

    func attach(_ view: MeterView) { views.add(view); view.render(bars) }
    func detach(_ view: MeterView) { views.remove(view) }

    // MARK: - Per frame

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = lastStep == 0 ? 1.0 / 60 : min(max(now - lastStep, 0.001), 0.1)
        lastStep = now

        let player = PlayerModel.shared
        // Nobody can see the bars (no Touch Bar, and the window minimised, hidden or fully covered):
        // stop every frame of work until the window shows again (see wake()).
        guard views.allObjects.contains(where: \.isShowing) else {
            for i in 0..<Self.barCount { bars[i] = 0; velocity[i] = 0 }
            link.isPaused = true
            return
        }
        let live = player.isPlaying && !player.muted
        record(time: now, level: live ? player.audioLevel() : 0)

        // The loudness heard right now sets the shared scale and the "hit" detector.
        let heard = level(at: now - Self.outputLatency)
        let heardDb = Self.decibels(heard)
        ceilingDb = max(heardDb, ceilingDb - Float(4 * dt), -30) // ceiling falls 4 dB/s, never below -30 dB
        let loudness = normalized(heardDb)
        slowLevel += (loudness - slowLevel) * CGFloat(1 - exp(-dt / 0.4))
        let punch = max(0, loudness - slowLevel)

        if live { clock += dt }
        var resting = !live
        for i in 0..<Self.barCount {
            var target: CGFloat = 0
            if live {
                let own = normalized(Self.decibels(level(at: now - Self.outputLatency - lags[i])))
                let ripple = 1 + 0.06 * CGFloat(sin(clock * rippleSpeeds[i] + Double(i) * 1.2))
                target = min(1, gains[i] * (0.85 * own + punch) * ripple)
            }
            // Critically damped spring, integrated exactly (stable for any frame time).
            let omega: CGFloat = target > bars[i] ? 30 : 13
            let e = CGFloat(exp(-Double(omega) * dt))
            let offset = bars[i] - target
            let carry = (velocity[i] + omega * offset) * CGFloat(dt)
            bars[i] = max(0, target + (offset + carry) * e)
            velocity[i] = (velocity[i] - omega * carry) * e
            if bars[i] > 0.003 || abs(velocity[i]) > 0.01 { resting = false }
        }
        if resting {
            for i in 0..<Self.barCount { bars[i] = 0; velocity[i] = 0 }
            link.isPaused = true // nothing to animate until playback resumes
        }
        for view in views.allObjects { view.render(bars) }
    }

    private func record(time: CFTimeInterval, level: Float) {
        head = (head + 1) % Self.historySize
        times[head] = time
        levels[head] = level
    }

    /// The newest reading taken at or before `time`.
    private func level(at time: CFTimeInterval) -> Float {
        guard head >= 0 else { return 0 }
        var i = head
        for _ in 0..<Self.historySize {
            if times[i] <= time { return times[i] == 0 ? 0 : levels[i] }
            i = (i - 1 + Self.historySize) % Self.historySize
        }
        return 0
    }

    private static func decibels(_ peak: Float) -> Float { 20 * log10(max(peak, 0.0001)) }

    /// 0 at 30 dB below the recent ceiling, 1 at the ceiling.
    private func normalized(_ db: Float) -> CGFloat {
        let n = min(max((db - (ceilingDb - 30)) / 30, 0), 1)
        return CGFloat(pow(n, 1.3))
    }

    // MARK: - Look

    /// Colour of a bar by its position.
    static func color(at position: CGFloat) -> NSColor {
        // Soft tones from the app icon: glowing blue to icy white-blue.
        let stops: [(CGFloat, CGFloat, CGFloat)] = [(0.33, 0.62, 0.92), (0.55, 0.76, 0.94), (0.78, 0.89, 0.98)]
        let p = min(max(position, 0), 1) * CGFloat(stops.count - 1)
        let i = min(Int(p), stops.count - 2)
        let f = p - CGFloat(i)
        let a = stops[i], b = stops[i + 1]
        return NSColor(srgbRed: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f, alpha: 1)
    }
}

/// Draws the mirrored, rounded bars with one CALayer each. Used by the control panel and the
/// Touch Bar; the meter pushes new heights straight into the layers every frame.
final class MeterView: NSView {
    private let barWidth: CGFloat
    private let insetY: CGFloat
    /// The Touch Bar copy. Its window never reports itself as visible, so it is always counted as shown.
    private let onTouchBar: Bool
    private var barLayers: [CALayer] = []
    private var current: [CGFloat] = Array(repeating: 0, count: AudioMeter.barCount)

    init(barWidth: CGFloat = 2, insetY: CGFloat = 0, onTouchBar: Bool = false) {
        self.barWidth = barWidth
        self.insetY = insetY
        self.onTouchBar = onTouchBar
        super.init(frame: .zero)
        wantsLayer = true
        for i in 0..<AudioMeter.barCount {
            let bar = CALayer()
            let position = CGFloat(i) / CGFloat(max(AudioMeter.barCount - 1, 1))
            bar.backgroundColor = AudioMeter.color(at: position).withAlphaComponent(0.9).cgColor
            bar.cornerRadius = barWidth / 2
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 30) }

    /// True when someone can actually see these bars right now.
    /// The on-screen bars keep moving while the controls are faded out, so they are already live
    /// the moment the controls come back; they only rest while the whole window is out of sight.
    var isShowing: Bool {
        guard let window else { return false }
        return onTouchBar || window.occlusionState.contains(.visible)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { AudioMeter.shared.attach(self) } else { AudioMeter.shared.detach(self) }
    }

    override func layout() {
        super.layout()
        render(current)
    }

    func render(_ bars: [CGFloat]) {
        current = bars
        let rect = bounds.insetBy(dx: 0, dy: insetY)
        guard rect.height > 0, bars.count == barLayers.count else { return }
        let gap: CGFloat = 2
        let total = barWidth * CGFloat(bars.count) + gap * CGFloat(bars.count - 1)
        let startX = rect.minX + max(0, (rect.width - total) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true) // the spring already animates; no implicit fades
        // The loudest sound fills 60% of the space, so the bars stay small and calm.
        let maxHeight = rect.height * 0.6
        for (i, value) in bars.enumerated() {
            let height = max(barWidth, value * maxHeight)
            barLayers[i].frame = CGRect(x: startX + CGFloat(i) * (barWidth + gap), y: rect.midY - height / 2,
                                        width: barWidth, height: height)
        }
        CATransaction.commit()
    }
}

/// Live waveform for the on-screen control panel (same bars as the Touch Bar).
struct WaveformView: NSViewRepresentable {
    func makeNSView(context: Context) -> MeterView { MeterView(barWidth: 2) }
    func updateNSView(_ view: MeterView, context: Context) {}
}
