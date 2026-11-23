import AppKit
import SwiftUI

/// The NSView libvlc draws the video into.
final class VideoHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    // The Touch Bar follows the focused view, so the video view supplies the player's bar itself.
    override func makeTouchBar() -> NSTouchBar? {
        dbg("video view makeTouchBar")
        return TouchBarController.shared.bar
    }
    override func becomeFirstResponder() -> Bool {
        dbg("video view became first responder")
        return true
    }
}

struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// Playback position. It changes several times a second, so it lives apart from `PlayerModel`:
/// only the views that show the time watch it, and the rest of the window is not redrawn.
final class PlaybackClock: ObservableObject {
    @Published var timeMs: Double = 0
    @Published var lengthMs: Double = 0
}

/// Wraps a libvlc media player and publishes its state to SwiftUI.
final class PlayerModel: ObservableObject {
    static let shared = PlayerModel()

    let videoView = VideoHostView(frame: .zero)
    let clock = PlaybackClock()

    @Published var hasMedia = false
    // The level meter sleeps while nothing plays; these wake it.
    @Published var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            AudioMeter.shared.wake()
            keepDisplayAwake(isPlaying)
        }
    }
    var timeMs: Double {
        get { clock.timeMs }
        set { if clock.timeMs != newValue { clock.timeMs = newValue } }
    }
    var lengthMs: Double {
        get { clock.lengthMs }
        set { if clock.lengthMs != newValue { clock.lengthMs = newValue } }
    }
    @Published var volume: Double = 100
    @Published var muted = false { didSet { if muted != oldValue { AudioMeter.shared.wake() } } }
    @Published var rate: Float = 1
    @Published var title = ""
    @Published var subTracks: [MediaTrack] = []
    @Published var audioTracks: [MediaTrack] = []
    @Published var currentSub: Int32 = -1
    @Published var currentAudio: Int32 = -1
    @Published var errorText: String?
    @Published var isFullscreen = false
    @Published var controlsVisible = true
    /// Bumped to flash a big play/pause/skip symbol over the video.
    @Published var flashToken = 0
    private(set) var flashSymbol = "play.fill"
    /// Bumped on every skip back / forward: the skip arrows give Apple's small turn.
    @Published var skipBackToken = 0
    @Published var skipForwardToken = 0
    /// Target time shown in the middle of the video while a two-finger swipe scrubs.
    @Published var swipeLabel: String?
    /// Full screen with "show the instructor when the pointer moves" off: the chat stays closed
    /// until it is opened with ⌘B or the sparkles button.
    @Published var chatOpenInFullscreen = false
    var hoveringControls = false
    /// Frames shown on the Touch Bar scrubber.
    @Published var thumbs: [CGImage?] = []

    private(set) var currentURL: URL?
    private var instance: OpaquePointer?
    private var mp: OpaquePointer?
    private var timer: Timer?
    private var tickCount = 0
    private var ended = false
    private var lastState: Int32 = 0
    private var lastMouseMove = Date()
    private var snapshotCount = 0
    private var pendingResume: Double?
    private var firstPlayHandled = true
    private var restarting = false
    private var pauseOnStart = false
    private let thumbnailer = ThumbnailGenerator()
    private var thumbsRequested = false
    /// Set when Apple's decoder cannot read the open file, so the libVLC frame maker is used.
    private var fastThumbsFailed = false
    /// Keeps the display (and the Mac) awake while a video plays.
    private var awakeActivity: NSObjectProtocol?
    // Seeking: rapid requests (dragging, swiping, held arrow keys) are merged so the engine gets
    // at most one seek every `seekInterval`; the shown time follows the request at once.
    private var seekTarget: Double?
    private var seekWork: DispatchWorkItem?
    private var lastEngineSeek = Date.distantPast
    private var holdClockUntil = Date.distantPast
    private let seekInterval: TimeInterval = 0.12
    // Freeze watch: the picture stopping while the sound goes on.
    private var lastDisplayed: Int32 = -1
    private var lastDecoded: Int32 = 0
    private var lastLost: Int32 = 0
    private var frozenChecks = 0
    private var freezeRecoveries = 0
    /// Set after the hardware decoder froze twice on the open file; it is then decoded in software.
    private var softwareDecoding = false
    static let thumbCount = 70
    let snapshotDir: URL

    private init() {
        // Private (0700), unguessable folder for the frames handed to the AI.
        let temp = FileManager.default.temporaryDirectory
        Self.removeStaleSnapshotDirs(in: temp)
        snapshotDir = temp.appendingPathComponent("StudyOPlayer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        Prefs.register()
        if Prefs.bool(Prefs.rememberVolume) { volume = max(0, min(Prefs.double(Prefs.volume), 125)) }
        rate = Float(Prefs.double(Prefs.defaultRate))
        setupVLC()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.05 // lets macOS group wake-ups with other work, which saves energy
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Frame folders left behind by a run that did not quit normally (crash, forced quit).
    /// Only folders older than a day are removed, so another running copy is never disturbed.
    private static func removeStaleSnapshotDirs(in temp: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for item in items where item.lastPathComponent.hasPrefix("StudyOPlayer-") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: item) }
        }
    }

    // MARK: - libvlc setup

    /// True when the engine is libVLC 3, whose internals the live audio level relies on.
    private(set) var levelMeterSupported = false

    private func setupVLC() {
        // Plugins live next to the libs: inside our bundle, or in VLC.app as a fallback.
        let bundled = Bundle.main.bundlePath + "/Contents/Frameworks/plugins"
        let system = "/Applications/VLC.app/Contents/MacOS/plugins"
        let plugins = FileManager.default.fileExists(atPath: bundled) ? bundled : system
        setenv("VLC_PLUGIN_PATH", plugins, 1)

        // No network lookups, no interactive prompts: this is a local-file player.
        // --no-osd: the engine never draws its own text (file paths, status) over the picture.
        var args = ["--no-video-title-show", "--quiet", "--snapshot-format=jpg", "--no-snapshot-preview",
                    "--no-metadata-network-access", "--no-interact", "--no-osd"]
        #if SELFTEST
        if ProcessInfo.processInfo.environment["STUDYO_VLC_VERBOSE"] != nil {
            args.removeAll { $0 == "--quiet" }
            args.append("--verbose=2")
        }
        #endif
        let scale = UserDefaults.standard.integer(forKey: Prefs.subScale)
        func start(_ list: [String]) -> OpaquePointer? {
            let cArgs: [UnsafeMutablePointer<CChar>?] = list.map { strdup($0) }
            defer { cArgs.forEach { free($0) } } // libvlc copies what it needs
            return cArgs.map { UnsafePointer($0) }.withUnsafeBufferPointer {
                libvlc_new(Int32(list.count), $0.baseAddress)
            }
        }
        // The live level reading uses libVLC 3 internals; on any other engine it stays off
        // instead of reading memory laid out differently.
        let version = libvlc_get_version().map { String(cString: $0) } ?? ""
        levelMeterSupported = version.hasPrefix("3.")
        dbg("engine version \(version), level meter: \(levelMeterSupported)")
        // The level-meter filter listens to the sound (it does not change it) and publishes
        // the loudness, which drives the waveform in the control panel and the Touch Bar.
        let meter = levelMeterSupported ? ["--audiobargraph_a-bargraph_repetition=1",
                                           "--audiobargraph_a-silence=0"] : []
        let subs = ["--sub-text-scale=\(max(50, min(scale, 300)))"]
        instance = start(args + subs + meter)
        if instance == nil {
            levelMeterSupported = false
            instance = start(args + subs) ?? start(args)
        }
        guard let instance else {
            errorText = L("Could not start the video engine.")
            return
        }
        mp = libvlc_media_player_new(instance)
        if let mp {
            libvlc_media_player_set_nsobject(mp, Unmanaged.passUnretained(videoView).toOpaque())
            if levelMeterSupported { enableLevelMeter(on: mp) }
        }
    }

    /// Switches the level-meter filter on. A media player owns an audio output object that keeps
    /// its own filter list, so the setting has to be made on that object (and on the player,
    /// for outputs created later).
    private func enableLevelMeter(on mp: OpaquePointer) {
        let stringType: Int32 = 0x0040
        func set(_ object: UnsafeMutableRawPointer) {
            var value = vlc_value_t()
            value.psz_string = strdup("audiobargraph_a")
            _ = var_SetChecked(object, "audio-filter", stringType, value)
            free(value.psz_string)
        }
        let player = UnsafeMutableRawPointer(mp)
        set(player)
        guard let children = vlc_list_children(player) else { return }
        defer { vlc_list_release(children) }
        for i in 0..<Int(children.pointee.i_count) {
            guard let child = children.pointee.p_values[i].p_address else { continue }
            // Every engine object starts with a pointer to its type name.
            if let type = child.load(as: UnsafePointer<CChar>?.self), String(cString: type) == "audio output" {
                set(child)
                dbg("level meter enabled on the audio output")
            }
        }
    }

    // MARK: - Opening media

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Choose a video or audio file")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// A subtitle file the user added by hand for the current video (also read by the AI).
    private(set) var addedSubtitleURL: URL?

    func open(_ url: URL) {
        guard let instance, let mp else { return }
        // Security: only local files are ever opened, never network addresses.
        var isDir: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let media = libvlc_media_new_path(instance, url.path) else {
            errorText = L("This file could not be opened.")
            return
        }
        saveResumePosition()
        cancelPendingSeek()
        if !restarting { softwareDecoding = false; freezeRecoveries = 0 }
        resetFreezeWatch()
        libvlc_media_add_option(media, Prefs.bool(Prefs.subAutoload) ? ":sub-autodetect-file" : ":no-sub-autodetect-file")
        if softwareDecoding { libvlc_media_add_option(media, ":avcodec-hw=none") }
        libvlc_media_player_set_media(mp, media)
        libvlc_media_release(media)
        currentURL = url
        firstPlayHandled = false
        pauseOnStart = !restarting && !Prefs.bool(Prefs.autoPlay)
        pendingResume = nil
        if !restarting {
            rate = Float(Prefs.double(Prefs.defaultRate))
            addedSubtitleURL = nil
            if Prefs.bool(Prefs.resume), let saved = Self.loadResumePositions()[url.path]?.first, saved > 5000 {
                pendingResume = saved
            }
        }
        title = url.lastPathComponent
        thumbs = []
        thumbsRequested = false
        fastThumbsFailed = false
        thumbnailer.cancel()
        hasMedia = true
        ended = false
        errorText = nil
        timeMs = 0
        lengthMs = 0
        subTracks = []
        audioTracks = []
        libvlc_media_player_play(mp)
        libvlc_media_player_set_rate(mp, rate)
        startThumbnailsIfNeeded() // starts as the file opens, not when playback begins
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        NotificationCenter.default.post(name: .studyoMediaOpened, object: url)
        focusVideo()
    }

    func addSubtitleFile() {
        guard let mp, hasMedia else { return }
        let panel = NSOpenPanel()
        panel.message = L("Choose a subtitle file (.srt, .ass, .vtt…)")
        if panel.runModal() == .OK, let url = panel.url {
            if libvlc_media_player_add_slave(mp, 0, url.absoluteString, true) == 0 { addedSubtitleURL = url }
        }
    }

    // MARK: - Transport

    func togglePlay() {
        guard let mp, hasMedia else { return }
        if ended, let url = currentURL {
            restart(url)
            flash("play.fill")
            return
        }
        if libvlc_media_player_is_playing(mp) != 0 {
            libvlc_media_player_set_pause(mp, 1)
            isPlaying = false
            flash("pause.fill")
        } else {
            libvlc_media_player_play(mp)
            isPlaying = true
            flash("play.fill")
        }
        pokeControls()
    }

    func pause() {
        guard let mp, hasMedia, libvlc_media_player_is_playing(mp) != 0 else { return }
        libvlc_media_player_set_pause(mp, 1)
        isPlaying = false
    }

    func seek(toMs ms: Double) {
        guard mp != nil, hasMedia else { return }
        let clamped = max(0, min(ms, max(lengthMs - 500, 0)))
        if ended, let url = currentURL {
            // The file has to be reopened; the engine ignores a seek until it is playing again,
            // so the position is applied once playback starts (see tick()).
            restart(url, at: clamped)
            timeMs = clamped
            return
        }
        timeMs = clamped
        holdClockUntil = Date().addingTimeInterval(0.7)
        seekTarget = clamped
        let wait = seekInterval - Date().timeIntervalSince(lastEngineSeek)
        if wait <= 0 {
            applySeek()
        } else if seekWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.applySeek() }
            seekWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    /// Hands the latest requested position to the engine.
    private func applySeek() {
        seekWork = nil
        guard let mp, let target = seekTarget else { return }
        seekTarget = nil
        lastEngineSeek = Date()
        holdClockUntil = Date().addingTimeInterval(0.7) // the engine reports the old time for a moment
        resetFreezeWatch()
        libvlc_media_player_set_time(mp, Int64(target))
    }

    private func cancelPendingSeek() {
        seekWork?.cancel()
        seekWork = nil
        seekTarget = nil
    }

    func skip(_ seconds: Double) {
        guard hasMedia else { return }
        seek(toMs: timeMs + seconds * 1000)
        flash(Self.skipSymbol(forward: seconds > 0, seconds: seconds))
        if seconds < 0 { skipBackToken += 1 } else { skipForwardToken += 1 }
        pokeControls()
    }

    /// Skip by the step chosen in Settings (arrow keys).
    func skipStep(forward: Bool) {
        let step = max(1, Prefs.double(Prefs.seekStep))
        skip(forward ? step : -step)
    }

    private func flash(_ symbol: String) {
        flashSymbol = symbol
        flashToken += 1
    }

    /// Apple's skip symbol with the number inside when one exists (5, 10, 15, 30…).
    static func skipSymbol(forward: Bool, seconds: Double) -> String {
        let base = forward ? "goforward" : "gobackward"
        let n = Int(abs(seconds).rounded())
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(n) ? "\(base).\(n)" : base
    }

    /// Stops the screen from dimming and the Mac from sleeping while a video plays.
    private func keepDisplayAwake(_ awake: Bool) {
        if awake, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "Playing a video")
        } else if !awake, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }

    /// Shows or hides the instructor (⌘B and the sparkles button).
    func toggleAssistant() {
        let defaults = UserDefaults.standard
        let shown = defaults.bool(forKey: "showAI")
        if isFullscreen && !Prefs.bool(Prefs.chatFollowsPointer) {
            if shown && chatOpenInFullscreen {
                chatOpenInFullscreen = false
            } else {
                defaults.set(true, forKey: "showAI")
                chatOpenInFullscreen = true
            }
        } else {
            defaults.set(!shown, forKey: "showAI")
        }
    }

    /// Whether the instructor panel is on screen now.
    func assistantVisible(showAI: Bool) -> Bool {
        guard showAI else { return false }
        guard isFullscreen else { return true }
        return Prefs.bool(Prefs.chatFollowsPointer) ? controlsVisible : chatOpenInFullscreen
    }

    /// Plays the current file again from the start (after it ended, or when repeating).
    private func restart(_ url: URL, at startMs: Double? = nil) {
        restarting = true
        let subtitle = addedSubtitleURL
        open(url)
        restarting = false
        pendingResume = startMs.flatMap { $0 > 0 ? $0 : nil }
        // Bring back a subtitle file that was added by hand.
        if let subtitle, let mp, libvlc_media_player_add_slave(mp, 0, subtitle.absoluteString, true) == 0 {
            addedSubtitleURL = subtitle
        }
    }

    /// Saved positions: path → [position in ms, time saved]. The time lets the oldest entry go first.
    private static func loadResumePositions() -> [String: [Double]] {
        (UserDefaults.standard.dictionary(forKey: Prefs.resumePositions) as? [String: [Double]]) ?? [:]
    }

    private var lastSavedResume: (path: String, ms: Double?)?

    private func saveResumePosition() {
        guard let url = currentURL, lengthMs > 0 else { return }
        // Finished (or barely started) videos start over next time.
        let keep = timeMs > 5000 && timeMs < lengthMs - 10_000
        let value: Double? = keep ? timeMs : nil
        // Skip the write when nothing meaningful changed (this runs every few seconds while playing).
        if let last = lastSavedResume, last.path == url.path {
            switch (last.ms, value) {
            case (nil, nil): return
            case let (a?, b?) where abs(a - b) < 1000: return
            default: break
            }
        }
        lastSavedResume = (url.path, value)
        var all = Self.loadResumePositions()
        if let value { all[url.path] = [value, Date().timeIntervalSince1970] } else { all[url.path] = nil }
        while all.count > 300, let oldest = all.min(by: { ($0.value.last ?? 0) < ($1.value.last ?? 0) })?.key {
            all.removeValue(forKey: oldest)
        }
        UserDefaults.standard.set(all, forKey: Prefs.resumePositions)
    }

    func prepareToQuit() { saveResumePosition() }

    func setVolume(_ v: Double) {
        volume = max(0, min(v, 125))
        if let mp { libvlc_audio_set_volume(mp, Int32(volume)) }
        if Prefs.bool(Prefs.rememberVolume) { UserDefaults.standard.set(volume, forKey: Prefs.volume) }
        if muted && volume > 0 { toggleMute() }
    }

    func toggleMute() {
        muted.toggle()
        if let mp { libvlc_audio_set_mute(mp, muted ? 1 : 0) }
    }

    func setRate(_ r: Float) {
        rate = r
        if let mp { libvlc_media_player_set_rate(mp, r) }
    }

    func selectSub(_ id: Int32) {
        if let mp { libvlc_video_set_spu(mp, id) }
        currentSub = id
    }

    func selectAudio(_ id: Int32) {
        if let mp { libvlc_audio_set_track(mp, id) }
        currentAudio = id
    }

    func toggleFullscreen() {
        (videoView.window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    /// Gives keyboard and Touch Bar focus to the video (away from the chat box).
    func focusVideo() {
        DispatchQueue.main.async { [videoView] in videoView.window?.makeFirstResponder(videoView) }
    }

    func pokeControls() {
        lastMouseMove = Date()
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        }
    }

    // MARK: - Live audio level

    /// Playback position straight from the engine, in ms (for timing measurements).
    func engineTimeMs() -> Double { mp.map { Double(libvlc_media_player_get_time($0)) } ?? 0 }

    /// Loudness of the sound being played right now, 0...1 (peak across channels).
    func audioLevel() -> Float {
        guard levelMeterSupported, let instance, hasMedia else { return 0 }
        // The public libvlc handle starts with a pointer to the engine's core object.
        guard let core = UnsafeRawPointer(instance).load(as: UnsafeMutableRawPointer?.self) else { return 0 }
        var value = vlc_value_t()
        guard var_GetChecked(core, "audiobargraph_v-i_values", 0x0040, &value) == 0,
              let text = value.psz_string else { return 0 }
        defer { free(text) }
        let peaks = String(cString: text).split(separator: ":").compactMap { Float($0) }
        return min(max(peaks.max() ?? 0, 0), 1)
    }

    // MARK: - Snapshot for the AI

    /// Saves the frame currently on screen as a JPEG and returns its URL.
    /// Main actor: it shares the player's state with the playback timer.
    @MainActor func snapshot(width: UInt32 = 1280) async -> URL? {
        guard let mp, hasMedia else { return nil }
        snapshotCount += 1
        let url = snapshotDir.appendingPathComponent("frame-\(snapshotCount).jpg")
        try? FileManager.default.removeItem(at: url)
        guard libvlc_video_take_snapshot(mp, 0, url.path, width, 0) == 0 else { return nil }
        for _ in 0..<30 {
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 0 {
                try? await Task.sleep(nanoseconds: 80_000_000) // let the writer finish
                return url
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: - Polling

    private func tick() {
        guard let mp, hasMedia else { return }
        tickCount += 1
        let state = libvlc_media_player_get_state(mp)
        let playing = state == 3 || state == 1 || state == 2
        if playing != isPlaying { isPlaying = playing }
        if state == 3 && lastState != 3 {
            libvlc_audio_set_volume(mp, Int32(volume))
            libvlc_audio_set_mute(mp, muted ? 1 : 0)
            refreshTracks()
            startThumbnailsIfNeeded()
            if !firstPlayHandled {
                firstPlayHandled = true
                if let resume = pendingResume {
                    libvlc_media_player_set_time(mp, Int64(resume))
                    pendingResume = nil
                }
                if pauseOnStart {
                    libvlc_media_player_set_pause(mp, 1)
                }
            }
        }
        if state == 6 && !ended {
            if Prefs.bool(Prefs.loop), let url = currentURL {
                restart(url)
                return
            }
            ended = true
            timeMs = lengthMs
            saveResumePosition()
        }
        if state == 7 && lastState != 7 {
            errorText = L("This file could not be played.")
        }
        lastState = state

        if !ended {
            let len = Double(libvlc_media_player_get_length(mp))
            if len > 0 && len != lengthMs { lengthMs = len }
            let t = Double(libvlc_media_player_get_time(mp))
            // Right after a seek the engine still reports the old time; keep the requested one.
            if t >= 0 && abs(t - timeMs) > 100 && seekTarget == nil && Date() >= holdClockUntil { timeMs = t }
        }
        if state == 3 && tickCount % 4 == 0 { watchForFrozenPicture(mp) }
        if tickCount % 8 == 0 { refreshTracks() }
        if !thumbsRequested { startThumbnailsIfNeeded() } // e.g. the Touch Bar has just appeared

        // Controls fade away while the video plays and the pointer rests; any movement brings them back.
        if isPlaying && controlsVisible && !hoveringControls && Date().timeIntervalSince(lastMouseMove) > 2.5 {
            withAnimation(.easeInOut(duration: 0.35)) { controlsVisible = false }
            if isFullscreen { NSCursor.setHiddenUntilMouseMoves(true) }
        } else if !isPlaying && !controlsVisible {
            withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        }
        if tickCount % 20 == 0 { saveResumePosition() }
        let level: NSWindow.Level = (Prefs.bool(Prefs.keepOnTop) && isPlaying) ? .floating : .normal
        if let window = videoView.window, window.level != level, !isFullscreen { window.level = level }
    }

    private func resetFreezeWatch() {
        lastDisplayed = -1
        frozenChecks = 0
    }

    /// Once a second while playing: if the decoder keeps producing frames (or dropping them as late)
    /// but none reaches the screen, the picture has frozen while the sound goes on. A seek to the
    /// current position restarts the picture; if it freezes again, the file is reopened with
    /// software decoding at the same spot.
    private func watchForFrozenPicture(_ mp: OpaquePointer) {
        guard let media = libvlc_media_player_get_media(mp) else { return }
        defer { libvlc_media_release(media) }
        var stats = libvlc_media_stats_t()
        guard libvlc_media_get_stats(media, &stats) != 0 else { return }
        let displayed = stats.i_displayed_pictures, decoded = stats.i_decoded_video, lost = stats.i_lost_pictures
        defer { lastDisplayed = displayed; lastDecoded = decoded; lastLost = lost }
        // Audio only, a cover picture, or the first reading after a seek: nothing to compare.
        guard lastDisplayed >= 0, decoded > 30, Date() >= holdClockUntil else { frozenChecks = 0; return }
        let stuck = displayed == lastDisplayed && (decoded > lastDecoded || lost > lastLost)
        frozenChecks = stuck ? frozenChecks + 1 : 0
        guard frozenChecks >= 2 else { return }
        frozenChecks = 0
        freezeRecoveries += 1
        let now = Double(libvlc_media_player_get_time(mp))
        dbg("frozen picture at \(Int(now)) ms, recovery \(freezeRecoveries)")
        if freezeRecoveries >= 2, !softwareDecoding, let url = currentURL {
            softwareDecoding = true
            restart(url, at: now)
        } else {
            libvlc_media_player_set_time(mp, Int64(max(now, 0)))
            resetFreezeWatch()
        }
    }

    /// Fills the Touch Bar strip: Apple's hardware decoder first (MP4/MOV, under a second), and
    /// libVLC for every other format once the video size is known. Nothing is saved to disk.
    private func startThumbnailsIfNeeded() {
        // Only for a Touch Bar that is actually showing; tick() tries again if one appears later.
        guard let url = currentURL, !thumbsRequested, TouchBarController.shared.stripVisible else { return }
        let deliver: (Int, CGImage) -> Void = { [weak self] index, image in
            guard let self, self.currentURL == url, index < self.thumbs.count else { return }
            self.thumbs[index] = image
        }
        if !fastThumbsFailed {
            thumbsRequested = true
            thumbs = Array(repeating: nil, count: Self.thumbCount)
            thumbnailer.startFast(url: url, count: Self.thumbCount, deliver: deliver) { [weak self] in
                guard let self, self.currentURL == url else { return }
                self.fastThumbsFailed = true
                self.thumbsRequested = false // the libVLC path takes over on the next tick
            }
            return
        }
        guard let mp, let instance else { return }
        var w: UInt32 = 0, h: UInt32 = 0
        guard libvlc_video_get_size(mp, 0, &w, &h) == 0, w > 0, h > 0 else { return } // audio only, or not ready
        thumbsRequested = true
        thumbs = Array(repeating: nil, count: Self.thumbCount)
        thumbnailer.start(instance: instance, url: url, aspect: Double(w) / Double(h),
                          count: Self.thumbCount, deliver: deliver)
    }

    private func refreshTracks() {
        guard let mp else { return }
        let subs = readTracks(libvlc_video_get_spu_description(mp))
        if subs != subTracks { subTracks = subs }
        let audio = readTracks(libvlc_audio_get_track_description(mp))
        if audio != audioTracks { audioTracks = audio }
        let s = libvlc_video_get_spu(mp)
        if s != currentSub { currentSub = s }
        let a = libvlc_audio_get_track(mp)
        if a != currentAudio { currentAudio = a }
    }

    private func readTracks(_ head: UnsafeMutablePointer<libvlc_track_description_t>?) -> [MediaTrack] {
        var result: [MediaTrack] = []
        var node = head
        while let n = node {
            let name = n.pointee.psz_name.map { String(cString: $0) } ?? "Track \(n.pointee.i_id)"
            result.append(MediaTrack(id: n.pointee.i_id, name: name))
            node = n.pointee.p_next
        }
        if let head { libvlc_track_description_list_release(head) }
        return result
    }
}

extension Notification.Name {
    static let studyoMediaOpened = Notification.Name("studyoMediaOpened")
}

func formatTime(_ ms: Double) -> String {
    let total = Int(max(ms, 0) / 1000)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
