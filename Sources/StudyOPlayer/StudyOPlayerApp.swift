import AppKit
import Combine
import SwiftUI

@main
struct StudyOPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var lang = Lang.shared
    @AppStorage("showAI") private var showAI = true
    @AppStorage("aiSide") private var aiSide = "right"
    @AppStorage(Prefs.appearance) private var appearance = "system"

    init() {
        // Every launch starts with the chat panel open, whatever it was when the app last quit.
        UserDefaults.standard.set(true, forKey: "showAI")
    }

    var body: some Scene {
        Window("StudyO Player", id: "main") {
            ContentView()
                .environmentObject(PlayerModel.shared)
                .environmentObject(AIModel.shared)
                .environmentObject(lang)
                .frame(minWidth: 1040, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 1240, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("About StudyO Player")) { AboutPanel.show() }
            }
            CommandGroup(replacing: .help) {
                Button(L("Contact Support…")) { AppInfo.contactSupport() }
                    .disabled(AppInfo.supportEmail.isEmpty)
            }
            CommandGroup(replacing: .newItem) {
                Button(L("Open…")) { PlayerModel.shared.openPanel() }.keyboardShortcut("o")
                Button(L("Add Subtitle File…")) { PlayerModel.shared.addSubtitleFile() }
            }
            CommandMenu(L("Playback")) {
                Button(L("Play / Pause")) { PlayerModel.shared.togglePlay() }
                Button(L("Back 10 s")) { PlayerModel.shared.skip(-10) }
                Button(L("Forward 10 s")) { PlayerModel.shared.skip(10) }
                Divider()
                Button(L("Full Screen")) { PlayerModel.shared.toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandMenu(L("Display")) {
                // (Settings… ⌘, is in the app menu, added by the Settings scene below.)
                Button(showAI ? L("Hide Instructor") : L("Show Instructor")) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { showAI.toggle() }
                }
                .keyboardShortcut("b")
                Button((aiSide != "right" ? "✓ " : "") + L("Instructor on the Left")) { aiSide = "left" }
                Button((aiSide == "right" ? "✓ " : "") + L("Instructor on the Right")) { aiSide = "right" }
                Divider()
                Menu(L("Appearance")) {
                    ForEach([("system", "System"), ("light", "Light"), ("dark", "Dark")], id: \.0) { value, name in
                        Button((appearance == value ? "✓ " : "") + L(name)) {
                            appearance = value
                            Prefs.applyAppearance()
                        }
                    }
                }
                Menu(L("Language")) {
                    Button((lang.setting == "system" ? "✓ " : "") + L("System")) { lang.setting = "system" }
                    Button((lang.setting == "ar" ? "✓ " : "") + "العربية") { lang.setting = "ar" }
                    Button((lang.setting == "en" ? "✓ " : "") + "English") { lang.setting = "en" }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(AIModel.shared)
                .environmentObject(lang)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?
    private var chromeWatch: AnyCancellable?
    private var pinchTotal: CGFloat = 0
    private var pinchFired = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.applyAppearance()
        signal(SIGPIPE, SIG_IGN) // a helper tool quitting early must never take the app down

        let player = PlayerModel.shared
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { _ in
            player.isFullscreen = true
        }
        nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { _ in
            player.isFullscreen = false
            player.controlsVisible = true
        }
        DispatchQueue.main.async {
            NSApp.windows.forEach {
                $0.acceptsMouseMovedEvents = true
                $0.isMovableByWindowBackground = true
            }
            player.focusVideo()
        }
        // The window's close/minimise/zoom buttons fade away with the playback controls.
        chromeWatch = player.$controlsVisible.receive(on: RunLoop.main).sink { visible in
            guard let window = player.videoView.window, !player.isFullscreen,
                  let strip = window.standardWindowButton(.closeButton)?.superview else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = visible ? 0.18 : 0.35
                strip.animator().alphaValue = (visible || !player.hasMedia) ? 1 : 0
            }
        }
        TouchBarController.shared.install()
        AudioMeter.shared.start()
        #if SELFTEST
        runSelfTest()
        #endif

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .magnify]) { [weak self] event in
            // Player shortcuts belong to the player window only: Space, arrows and letters keep
            // their normal meaning in Settings, About and open panels.
            guard let window = event.window, window === player.videoView.window else { return event }
            switch event.type {
            case .mouseMoved:
                player.pokeControls()
                return event
            case .magnify:
                self?.handlePinch(event)
                return event
            default:
                break
            }
            // Keyboard shortcuts (ignored while typing in the chat box).
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            switch event.keyCode {
            case 49: player.togglePlay()                      // space
            case 123: player.skipStep(forward: false)         // ←
            case 124: player.skipStep(forward: true)          // →
            case 126: player.setVolume(player.volume + 5)     // ↑
            case 125: player.setVolume(player.volume - 5)     // ↓
            case 3: player.toggleFullscreen()                 // F
            case 46: player.toggleMute()                      // M
            case 53 where player.isFullscreen: player.toggleFullscreen() // esc
            default: return event
            }
            return nil
        }
    }

    /// Trackpad pinch: spread two fingers to enter full screen, pinch them together to leave it.
    private func handlePinch(_ event: NSEvent) {
        if event.phase.contains(.began) {
            pinchTotal = 0
            pinchFired = false
        }
        pinchTotal += event.magnification
        guard !pinchFired else { return }
        let player = PlayerModel.shared
        if pinchTotal > 0.2 && !player.isFullscreen {
            pinchFired = true
            player.toggleFullscreen()
        } else if pinchTotal < -0.2 && player.isFullscreen {
            pinchFired = true
            player.toggleFullscreen()
        }
    }

    #if SELFTEST
    /// Developer smoke test, compiled only by `./build.sh --selftest`:
    /// STUDYO_SELFTEST="question" STUDYO_SELFTEST_FILE=/path/video  → plays, asks, prints, quits.
    private func runSelfTest() {
        let env = ProcessInfo.processInfo.environment
        if let out = env["STUDYO_SELFTEST_ABOUT"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                AboutPanel.show()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let view = NSApp.keyWindow?.contentView?.superview,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let out = env["STUDYO_SELFTEST_LOOK"] {
            // Pictures of the empty window and of Settings, then quit.
            Task { @MainActor in
                func shoot(_ window: NSWindow?, _ path: String) {
                    guard let view = window?.contentView?.superview,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                let main = NSApp.windows.first { $0.isVisible }
                shoot(main, out + "-empty.png")
                if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
                   let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                shoot(NSApp.windows.first { $0.isVisible && $0 !== main }, out + "-settings.png")
                AboutPanel.show()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // Report how far each window's centre is from the screen's centre (x only; macOS
                // places "centred" windows a little above the middle on purpose).
                for w in NSApp.windows where w.isVisible {
                    guard let screen = w.screen else { continue }
                    let off = Int(w.frame.midX - screen.visibleFrame.midX)
                    print("window \(Int(w.frame.width))x\(Int(w.frame.height)) horizontal offset from centre: \(off)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let file = env["STUDYO_SELFTEST_AUDIO"] {
            // Plays a sound file and prints the live audio level a few times, then quits.
            PlayerModel.shared.open(URL(fileURLWithPath: file))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                var samples: [String] = []
                for _ in 0..<16 {
                    samples.append(String(format: "%.2f", PlayerModel.shared.audioLevel()))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                print("audio levels:", samples.joined(separator: " "))
                // How far ahead of the speakers is the level reading? The test tone turns loud
                // exactly on each whole second of the file. The engine clock is coarse, so it is
                // fitted against the wall clock first (its freshest readings sit on the upper edge),
                // then each loud edge is placed on that fitted clock.
                var onsets: [Double] = []
                var offsets: [Double] = []
                var barPeak = 0.0, barLow = 1.0
                var wasLoud = PlayerModel.shared.audioLevel() > 0.4
                let start = CACurrentMediaTime()
                for _ in 0..<2400 {
                    let wall = (CACurrentMediaTime() - start) * 1000
                    offsets.append(PlayerModel.shared.engineTimeMs() - wall)
                    let loud = PlayerModel.shared.audioLevel() > 0.4
                    if loud && !wasLoud { onsets.append(wall) }
                    wasLoud = loud
                    let tallest = Double(AudioMeter.shared.bars.max() ?? 0)
                    barPeak = max(barPeak, tallest); barLow = min(barLow, tallest)
                    try? await Task.sleep(nanoseconds: 4_000_000)
                }
                let clockOffset = offsets.sorted()[Int(Double(offsets.count) * 0.95)]
                let leads = onsets.map { w -> Int in
                    let media = Int(w + clockOffset)
                    return (1000 - media % 1000) % 1000
                }
                let gaps = zip(onsets.dropFirst(), onsets).map { Int($0 - $1) }
                print("level leads sound by (ms):", leads, "median:", leads.sorted()[leads.count / 2])
                print("gaps between loud edges (ms, ideal 1000):", gaps)
                print(String(format: "tallest bar ranged %.2f ... %.2f", barLow, barPeak))
                print("meter bars max:", String(format: "%.2f", Double(AudioMeter.shared.bars.max() ?? 0)))
                NSApp.terminate(nil)
            }
            return
        }
        if let file = env["STUDYO_SELFTEST_FIXES"] {
            // Checks the fixes for: seeking after the end, Stop before the tool starts,
            // and a new chat while an answer is still running.
            let player = PlayerModel.shared
            player.open(URL(fileURLWithPath: file))
            Task { @MainActor in
                let ai = AIModel.shared
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                player.seek(toMs: player.lengthMs - 800)
                for _ in 0..<40 where player.timeMs < player.lengthMs - 1 { try? await Task.sleep(nanoseconds: 100_000_000) }
                print("ended:", player.timeMs >= player.lengthMs - 1)
                player.seek(toMs: 5000)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                print("after seeking back from the end, time:", Int(player.timeMs), "(expect about 6000-7500)")

                await ai.detect(force: true)
                ai.selectedID = "claude"
                if !ai.isConnected(ai.selected) {
                    ai.connect()
                    while ai.connecting { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                ai.newChat()
                ai.send("Say hi.")
                try? await Task.sleep(nanoseconds: 30_000_000)
                ai.cancel()
                while ai.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
                print("stop before start → messages:", ai.messages.map(\.text), "(expect none: nothing was sent)")

                let before = ai.sessions.count
                ai.send("Describe this frame in detail.")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                ai.newChat()
                while ai.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
                try? await Task.sleep(nanoseconds: 500_000_000)
                print("new chat during an answer → messages:", ai.messages.count, "(expect 0); saved chats added:",
                      ai.sessions.count - before, "(expect 0)")
                NSApp.terminate(nil)
            }
            return
        }
        guard let question = env["STUDYO_SELFTEST"] else { return }
        let player = PlayerModel.shared
        if let file = env["STUDYO_SELFTEST_FILE"] { player.open(URL(fileURLWithPath: file)) }
        Task { @MainActor in
            let ai = AIModel.shared
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if let id = env["STUDYO_SELFTEST_AI"] { ai.selectedID = id }
            print("providers:", ai.providers.map { "\($0.id)[\($0.available ? "ok" : "off")]" })
            print("playing:", player.isPlaying, "time:", player.timeMs, "length:", player.lengthMs)
            print("chat restored for this video:", ai.messages.count, "messages; saved chats:", ai.sessions.count)
            print("thumbs ready:", player.thumbs.compactMap { $0 }.count, "of", player.thumbs.count)
            if let out = env["STUDYO_SELFTEST_STRIP"] {
                let strip = ScrubStripView(frame: NSRect(x: 0, y: 0, width: 940, height: 60))
                strip.thumbs = player.thumbs
                strip.progress = 0.4
                if let rep = strip.bitmapImageRepForCachingDisplay(in: strip.bounds) {
                    strip.cacheDisplay(in: strip.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
            }
            func shoot(_ path: String) {
                guard let view = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible })?.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if let out = env["STUDYO_SELFTEST_CONNECT_SHOT"] {
                // Picture of the sign-in screen: unlink, shoot, then link again below.
                if let p = ai.selected { ai.connected.remove(p.connectKey) }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                shoot(out)
            }
            if !ai.isConnected(ai.selected) {
                ai.connect()
                while ai.connecting { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            print("connected:", ai.isConnected(ai.selected), "account shown:", ai.accountPlan[ai.selected?.connectKey ?? ""] != nil)
            player.pause()
            ai.send(question)
            try? await Task.sleep(nanoseconds: 500_000_000)
            while ai.busy { try? await Task.sleep(nanoseconds: 300_000_000) }
            for m in ai.messages { print(m.role == .user ? "USER:" : "AI:", m.isError ? "(error)" : "", m.text) }
            print("saved chats after answer:", ai.sessions.count)
            print("frames left on disk:", (try? FileManager.default.contentsOfDirectory(atPath: player.snapshotDir.path))?.count ?? -1)
            if let out = env["STUDYO_SELFTEST_SHOT"] {
                player.pokeControls()
                try? await Task.sleep(nanoseconds: 600_000_000)
                shoot(out)
            }
            NSApp.terminate(nil)
        }
    }
    #endif

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.isFileURL }) { PlayerModel.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerModel.shared.prepareToQuit()
        ChatStore.flush() // let the last chat save finish
        try? FileManager.default.removeItem(at: PlayerModel.shared.snapshotDir)
    }
}

/// Maker details shown in About and used by Help → Contact Support.
enum AppInfo {
    /// Public support address. Leave empty to hide the support entries.
    static let supportEmail = "mohammedtalaatfayez@gmail.com"


    static func contactSupport() {
        guard !supportEmail.isEmpty else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = supportEmail
        parts.queryItems = [URLQueryItem(name: "subject", value: "StudyO Player \(version) — Support")]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}
