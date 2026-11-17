import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Look and feel

enum Theme {
    /// The app's colour: the glowing blue of the app icon, used for the few coloured elements.
    static let accent = Color(red: 0.19, green: 0.46, blue: 0.85)
    static let accentSoft = Color(red: 0.33, green: 0.62, blue: 0.92)
    static let accentGradient = LinearGradient(colors: [accent, accentSoft], startPoint: .topLeading, endPoint: .bottomTrailing)
    // These follow light and dark appearance.
    /// Your own chat bubbles.
    static let userBubble = accentGradient
    static let hairline = Color.primary.opacity(0.10)
    static let fill = Color.primary.opacity(0.07)
    /// Reply bubble: a solid grey that suits each appearance.
    static let replyBubble = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.90, alpha: 1)
    })
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)
}

/// Native macOS vibrancy (the frosted material Apple uses for sidebars).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

extension View {
    /// Floating glass panel: Liquid Glass on current macOS, frosted material on older systems.
    @ViewBuilder func glassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }
}

/// Buttons shrink slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A glyph button with a soft highlight on hover.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(hover ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white.opacity(hover ? 1 : 0.85))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var lang: Lang
    @AppStorage("showAI") private var showAI = true
    @AppStorage("aiSide") private var aiSide = "right"
    @AppStorage("aiWidth") private var aiWidth = 286.0
    @State private var dropTargeted = false
    @State private var dragBase: Double?

    private var sidebarVisible: Bool { showAI && !(player.isFullscreen && !player.controlsVisible) }
    private var onLeft: Bool { aiSide != "right" }

    var body: some View {
        GeometryReader { geo in
            // The chat can be widened or narrowed, always leaving room for the video.
            let width = CGFloat(min(max(aiWidth, 280), max(280, Double(geo.size.width) - 600)))
            HStack(spacing: 0) {
                if sidebarVisible && onLeft {
                    AISidebar(topInset: player.isFullscreen ? 14 : 40) // clear of the window buttons
                        .frame(width: width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    divider(direction: 1, total: geo.size.width)
                }
                PlayerStage(dropTargeted: dropTargeted)
                if sidebarVisible && !onLeft {
                    divider(direction: -1, total: geo.size.width)
                    AISidebar(topInset: 14)
                        .frame(width: width)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        // The window layout never mirrors: the assistant stays on the chosen side in Arabic too.
        .environment(\.layoutDirection, .leftToRight)
        // Asked once, after the welcome tour: open videos with StudyO by default?
        .overlay(alignment: .top) { DefaultPlayerPrompt() }
        .background(player.hasMedia ? Color.black : Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .animation(Theme.spring, value: sidebarVisible)
        .animation(Theme.spring, value: aiSide)
        .navigationTitle(player.title.isEmpty ? "StudyO Player" : player.title)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let item = providers.first else { return false }
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { player.open(url) } }
            }
            return true
        }
    }
}

extension ContentView {
    /// The line between chat and video. Drag it to resize the chat.
    func divider(direction: Double, total: CGFloat) -> some View {
        ResizeHandle(
            onDrag: { dx in
                let base = dragBase ?? aiWidth
                if dragBase == nil { dragBase = base }
                aiWidth = min(max(base + Double(dx) * direction, 280), max(280, Double(total) - 600))
            },
            onEnd: { dragBase = nil })
            .frame(width: 9)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1))
            .help(L("Drag to resize"))
    }
}

/// A thin strip that reports horizontal drags and shows the resize cursor.
struct ResizeHandle: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    final class HandleView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var startX: CGFloat = 0
        override var mouseDownCanMoveWindow: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) { startX = event.locationInWindow.x }
        override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x - startX) }
        override func mouseUp(with event: NSEvent) { onEnd?() }
    }

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
        view.onEnd = onEnd
    }
}

struct VideoSurface: NSViewRepresentable {
    /// False on the welcome screen, so its black background does not cover the light/dark window colour.
    /// The view stays in place (only transparent) so it keeps keyboard focus and the Touch Bar.
    var visible = true
    func makeNSView(context: Context) -> VideoHostView { PlayerModel.shared.videoView }
    func updateNSView(_ nsView: VideoHostView, context: Context) { nsView.alphaValue = visible ? 1 : 0 }
}

// MARK: - Video area with floating controls

struct PlayerStage: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var lang: Lang
    let dropTargeted: Bool
    @AppStorage("showAI") private var showAI = true
    @AppStorage("aiSide") private var aiSide = "right"
    /// The app's light/dark mode, read before this view forces dark over a video.
    @Environment(\.colorScheme) private var systemScheme

    /// Leaves room for the window buttons when the video reaches the window's top-left corner.
    private var titleInset: CGFloat {
        (player.isFullscreen || (showAI && aiSide != "right")) ? 18 : 84
    }

    private var chromeVisible: Bool { player.controlsVisible || !player.hasMedia }

    var body: some View {
        ZStack {
            // Black behind a video; the normal window colour (light or dark) on the welcome screen.
            (player.hasMedia ? Color.black : Color(nsColor: .windowBackgroundColor))
                .animation(.easeOut(duration: 0.25), value: player.hasMedia)
            VideoSurface(visible: player.hasMedia)
            // A click only moves focus to the video. Pausing is Space or the play button.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.toggleFullscreen() }
                .onTapGesture { player.focusVideo() }

            if !player.hasMedia {
                EmptyState(dropTargeted: dropTargeted)
                    .environment(\.layoutDirection, lang.direction)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            FlashIndicator()

            // Only the playback controls float over the picture. Opening files, the instructor
            // panel and Settings live in the menu bar; the file name is in the window title.
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    // Only the open file's name; nothing when no video is open.
                    Text(player.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1).truncationMode(.middle)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    Spacer(minLength: 12)
                    // Floating button: show or hide the instructor.
                    Button {
                        withAnimation(Theme.spring) { showAI.toggle() }
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(showAI ? AnyShapeStyle(Theme.accentGradient)
                                             : player.hasMedia ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                            .frame(width: 34, height: 34)
                            .glassPanel(cornerRadius: 17)
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .help(L("Show or hide the assistant"))
                    .onHover { player.hoveringControls = $0 }
                }
                .padding(.leading, titleInset)
                .padding(.trailing, 14)
                .padding(.top, 9)
                .padding(.bottom, 24)
                // The shade keeps the title readable over a video; nothing to shade on the welcome screen.
                .background(LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .opacity(player.hasMedia ? 1 : 0)
                    .allowsHitTesting(false))
                Spacer(minLength: 0)
                if player.hasMedia {
                    ControlHUD()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .offset(y: chromeVisible ? 0 : 14)
                }
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)

            if let error = player.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassPanel(cornerRadius: 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if dropTargeted && player.hasMedia {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 3)
                    .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(12)
                    .transition(.opacity)
            }
        }
        // Dark over a video, whatever the app appearance; the welcome screen follows light/dark mode.
        .environment(\.colorScheme, player.hasMedia ? .dark : systemScheme)
        .animation(Theme.spring, value: player.hasMedia)
        .animation(.easeOut(duration: 0.2), value: dropTargeted)
        .animation(Theme.spring, value: player.errorText)
    }
}

/// Big symbol that pops and fades over the video on play, pause and skip.
struct FlashIndicator: View {
    @EnvironmentObject var player: PlayerModel
    var body: some View {
        Image(systemName: player.flashSymbol)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 84, height: 84)
            .glassPanel(cornerRadius: 42)
            .phaseAnimator([0, 1, 2], trigger: player.flashToken) { view, phase in
                view.opacity(phase == 1 ? 1 : 0)
                    .scaleEffect(phase == 0 ? 0.7 : (phase == 1 ? 1 : 1.2))
            } animation: { phase in
                phase == 1 ? .spring(response: 0.22, dampingFraction: 0.7) : .easeIn(duration: 0.4)
            }
            .allowsHitTesting(false)
    }
}

struct EmptyState: View {
    /// Redraws this view when the app language changes.
    @ObservedObject private var lang = Lang.shared
    @EnvironmentObject var player: PlayerModel
    let dropTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Color.clear.frame(width: 120, height: 120)
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.42), Theme.accentSoft.opacity(0.12), .clear],
                                         center: .center, startRadius: 10, endRadius: 150))
                    .frame(width: 300, height: 300)
                    .frame(width: 120, height: 120) // the glow spills out without pushing the text away
                    // A still glow: an endless pulse would redraw the window every frame while idle.
                    .opacity(0.75)
                Group {
                    if dropTargeted {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 88)
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        // The app icon itself, so the welcome screen carries the brand.
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable().interpolation(.high)
                            .frame(width: 112, height: 112)
                    }
                }
                .shadow(color: Theme.accent.opacity(0.45), radius: 22, y: 10)
                .scaleEffect(dropTargeted ? 1.08 : 1)
                .animation(Theme.spring, value: dropTargeted)
            }
            VStack(spacing: 6) {
                Text("StudyO Player").font(.system(size: 28, weight: .bold, design: .rounded))
                Text(dropTargeted ? L("Drop to play") : L("Open a video, or drop one anywhere in this window."))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button { player.openPanel() } label: {
                Text(L("Open Video…"))
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(PressableStyle())
            Text("MKV · MP4 · MOV · AVI · WebM · FLV · WMV · TS")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(40)
        .animation(Theme.spring, value: dropTargeted)
    }
}

// MARK: - Floating control panel

/// Transport controls in a floating glass panel. Always left-to-right, like the timeline itself.
struct ControlHUD: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var lang: Lang

    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                HStack(spacing: 6) {
                    IconButton(symbol: volumeSymbol, help: L("Mute (M)")) { player.toggleMute() }
                    Slider(value: Binding(get: { player.muted ? 0 : player.volume }, set: { player.setVolume($0) }), in: 0...125)
                        .controlSize(.mini)
                        .tint(.white)
                        .frame(width: 70)
                    WaveformView()
                        .frame(width: 28, height: 18)
                        .padding(.leading, 6)
                    Spacer()
                    Menu {
                        Picker(L("Playback speed"), selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                            ForEach(rates, id: \.self) { r in Text(rateLabel(r)).tag(r) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(rateLabel(player.rate))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .frame(width: 38, height: 30)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("Playback speed"))

                    Menu {
                        Picker(L("Subtitles"), selection: Binding(get: { player.currentSub }, set: { player.selectSub($0) })) {
                            Text(L("Off")).tag(Int32(-1))
                            ForEach(player.subTracks.filter { $0.id != -1 }) { t in Text(t.name).tag(t.id) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button(L("Add Subtitle File…")) { player.addSubtitleFile() }
                    } label: { hudGlyph(player.currentSub == -1 ? "captions.bubble" : "captions.bubble.fill") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("Subtitles"))

                    Menu {
                        Picker(L("Audio track"), selection: Binding(get: { player.currentAudio }, set: { player.selectAudio($0) })) {
                            ForEach(player.audioTracks) { t in Text(t.name).tag(t.id) }
                        }
                        .pickerStyle(.inline)
                    } label: { hudGlyph("waveform") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(player.audioTracks.isEmpty)
                    .help(L("Audio track"))

                    IconButton(symbol: player.isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                                           : "arrow.up.left.and.arrow.down.right",
                               help: L("Full screen (F)")) { player.toggleFullscreen() }
                }
                HStack(spacing: 18) {
                    IconButton(symbol: "gobackward.10", size: 18, help: L("Back 10 seconds")) { player.skip(-10) }
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 44, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .foregroundStyle(.white)
                    .help(L("Play / Pause (Space)"))
                    IconButton(symbol: "goforward.10", size: 18, help: L("Forward 10 seconds")) { player.skip(10) }
                }
            }
            TimeRow(clock: player.clock)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: 660)
        .glassPanel(cornerRadius: 22)
        .environment(\.colorScheme, .dark)
        .onHover { player.hoveringControls = $0 }
    }

    private var volumeSymbol: String {
        if player.muted || player.volume == 0 { return "speaker.slash.fill" }
        return player.volume < 40 ? "speaker.wave.1.fill" : (player.volume < 85 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }

    private func rateLabel(_ r: Float) -> String { String(format: "%g×", r) }

    private func hudGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }
}

/// Elapsed time, timeline, remaining time. The only part of the panel that follows the clock.
struct TimeRow: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(clock.timeMs))
                .frame(minWidth: 42, alignment: .trailing)
            Scrubber(clock: clock)
            Text("-" + formatTime(max(clock.lengthMs - clock.timeMs, 0)))
                .frame(minWidth: 46, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
    }
}

/// The timeline: thin white bar that thickens under the pointer, with a time bubble while hovering.
struct Scrubber: View {
    @ObservedObject var clock: PlaybackClock
    private var player: PlayerModel { PlayerModel.shared }
    @State private var dragging = false
    @State private var dragFraction = 0.0
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let active = dragging || hoverX != nil
            let fraction = dragging
                ? dragFraction
                : (clock.lengthMs > 0 ? min(max(clock.timeMs / clock.lengthMs, 0), 1) : 0)
            let barHeight: CGFloat = active ? 7 : 4

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: barHeight)
                Capsule().fill(.white).frame(width: max(barHeight, width * fraction), height: barHeight)
                Circle().fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: min(max(width * fraction - 7, 0), width - 14))
                    .scaleEffect(active ? 1 : 0.01)
                    .opacity(active ? 1 : 0)
                if let x = hoverX, clock.lengthMs > 0 {
                    Text(formatTime(Double(min(max(x / width, 0), 1)) * clock.lengthMs))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.75), in: Capsule())
                        .fixedSize()
                        .offset(x: min(max(x - 22, 0), width - 46), y: -24)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        dragFraction = Double(min(max(value.location.x / width, 0), 1))
                        hoverX = value.location.x
                    }
                    .onEnded { value in
                        let f = Double(min(max(value.location.x / width, 0), 1))
                        player.seek(toMs: f * clock.lengthMs)
                        dragging = false
                    })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: if !dragging { hoverX = nil }
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        }
        .frame(height: 20)
    }
}
