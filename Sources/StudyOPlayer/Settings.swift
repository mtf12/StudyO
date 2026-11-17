import AppKit
import SwiftUI

/// Names and defaults of every saved preference.
enum Prefs {
    static let keepOnTop = "keepOnTop"
    static let resume = "resumePlayback"
    static let resumePositions = "resumePositions"
    static let autoPlay = "autoPlay"
    static let loop = "loopVideo"
    static let seekStep = "seekStep"
    static let defaultRate = "defaultRate"
    static let rememberVolume = "rememberVolume"
    static let volume = "volume"
    static let subAutoload = "subAutoload"
    static let subScale = "subScale"
    static let aiSendFrame = "aiSendFrame"
    static let aiSendSubs = "aiSendSubs"
    static let aiAnswerLang = "aiAnswerLang"

    /// Preference key holding the model name used for a cloud AI.
    static func model(_ kind: AIProvider.Kind) -> String { "aiModel." + kind.rawValue }

    static func register() {
        UserDefaults.standard.register(defaults: [
            keepOnTop: false, resume: true, autoPlay: true, loop: false, seekStep: 5.0, defaultRate: 1.0,
            rememberVolume: true, volume: 100.0, subAutoload: true, subScale: 100,
            aiSendFrame: true, aiSendSubs: true, aiAnswerLang: "auto",
        ])
    }

    /// "system", "light" or "dark". The video area itself always stays dark.
    static let appearance = "appearance"
    static func applyAppearance() {
        switch string(appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil // follow the system
        }
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    static func double(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    static func string(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
}

/// The Settings window (⌘,).
struct SettingsView: View {
    @EnvironmentObject var lang: Lang

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(L("General"), systemImage: "gearshape") }
            PlaybackSettings().tabItem { Label(L("Playback"), systemImage: "play.circle") }
            SubtitleSettings().tabItem { Label(L("Subtitles"), systemImage: "captions.bubble") }
            AISettings().tabItem { Label(L("Instructor"), systemImage: "sparkles") }
            ShortcutSettings().tabItem { Label(L("Shortcuts"), systemImage: "keyboard") }
        }
        .frame(width: 520, height: 440)
        .background(CenterWindowOnAppear())
        .environment(\.layoutDirection, lang.direction)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var lang: Lang
    @AppStorage("aiSide") private var aiSide = "right"
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = false
    @AppStorage(Prefs.resume) private var resume = true
    @AppStorage(Prefs.appearance) private var appearance = "system"

    var body: some View {
        Form {
            Section {
                Picker(L("Appearance"), selection: $appearance) {
                    Text(L("System")).tag("system")
                    Text(L("Light")).tag("light")
                    Text(L("Dark")).tag("dark")
                }
                .onChange(of: appearance) { _, _ in Prefs.applyAppearance() }
                Picker(L("Language"), selection: $lang.setting) {
                    Text(L("System")).tag("system")
                    Text("العربية").tag("ar")
                    Text("English").tag("en")
                }
                Picker(L("Instructor panel side"), selection: $aiSide) {
                    Text(L("Left")).tag("left")
                    Text(L("Right")).tag("right")
                }
            }
            Section {
                Toggle(L("Keep the window on top while playing"), isOn: $keepOnTop)
                Toggle(L("Continue each video where I stopped"), isOn: $resume)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlaybackSettings: View {
    @AppStorage(Prefs.autoPlay) private var autoPlay = true
    @AppStorage(Prefs.loop) private var loop = false
    @AppStorage(Prefs.seekStep) private var seekStep = 5.0
    @AppStorage(Prefs.defaultRate) private var defaultRate = 1.0
    @AppStorage(Prefs.rememberVolume) private var rememberVolume = true

    var body: some View {
        Form {
            Section {
                Toggle(L("Start playing as soon as a video opens"), isOn: $autoPlay)
                Toggle(L("Repeat the video when it ends"), isOn: $loop)
            }
            Section {
                Picker(L("Arrow keys skip"), selection: $seekStep) {
                    ForEach([5.0, 10.0, 15.0, 30.0], id: \.self) { s in
                        Text("\(Int(s)) " + L("seconds")).tag(s)
                    }
                }
                Picker(L("Default speed"), selection: $defaultRate) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0], id: \.self) { r in
                        Text(String(format: "%g×", r)).tag(r)
                    }
                }
                Toggle(L("Remember the volume"), isOn: $rememberVolume)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SubtitleSettings: View {
    @AppStorage(Prefs.subAutoload) private var autoload = true
    @AppStorage(Prefs.subScale) private var scale = 100

    var body: some View {
        Form {
            Section {
                Toggle(L("Load a subtitle file with the same name as the video"), isOn: $autoload)
            }
            Section {
                Picker(L("Subtitle size"), selection: $scale) {
                    Text(L("Small")).tag(75)
                    Text(L("Normal")).tag(100)
                    Text(L("Large")).tag(140)
                    Text(L("Very large")).tag(180)
                }
            } footer: {
                Text(L("The size applies the next time you open StudyO Player."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettings: View {
    @EnvironmentObject var ai: AIModel
    @AppStorage(Prefs.aiSendFrame) private var sendFrame = true
    @AppStorage(Prefs.aiSendSubs) private var sendSubs = true
    @AppStorage(Prefs.aiAnswerLang) private var answerLang = "auto"
    @AppStorage("aiModel.openai") private var openaiModel = ""
    @AppStorage("aiModel.geminiAPI") private var geminiModel = ""

    var body: some View {
        let provider = ai.selected
        let connected = ai.isConnected(provider)
        Form {
            Section {
                LabeledContent(provider?.name ?? L("No assistant found")) {
                    HStack(spacing: 8) {
                        Circle().fill(connected ? Color.green : Color.gray).frame(width: 7, height: 7)
                        Text(connected ? L("Connected") : L("Not connected")).foregroundStyle(.secondary)
                        if connected {
                            Button(L("Disconnect")) { ai.disconnect() }
                        } else if provider?.available == true {
                            Button(L("Sign In")) { ai.connect() }.disabled(ai.connecting)
                        }
                    }
                }
                if connected, let key = provider?.connectKey, let email = ai.accountEmail[key] {
                    LabeledContent(L("Account"), value: email)
                }
            }
            Section {
                Toggle(L("Send the current frame with my question"), isOn: $sendFrame)
                Toggle(L("Send nearby subtitle lines"), isOn: $sendSubs)
                Picker(L("Answer language"), selection: $answerLang) {
                    Text(L("Same as my question")).tag("auto")
                    Text("العربية").tag("ar")
                    Text("English").tag("en")
                }
            }
            Section {
                TextField(L("ChatGPT model"), text: $openaiModel)
                TextField(L("Gemini model"), text: $geminiModel)
            }
            Section {
                LabeledContent(L("Saved chats")) {
                    HStack {
                        Text("\(ai.sessions.count)").foregroundStyle(.secondary)
                        Button(L("Delete All")) { ai.clearHistory() }.disabled(ai.sessions.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    private let rows: [(String, String)] = [
        ("Space", "Play / Pause"), ("← →", "Skip back / forward"), ("↑ ↓", "Volume"),
        ("F", "Full Screen"), ("M", "Mute"), ("⌘O", "Open a video"), ("⌘B", "Show or hide the assistant"),
        ("⌘,", "Settings"),
    ]
    var body: some View {
        Form {
            Section {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(L(row.1)) {
                        Text(row.0)
                            .font(.system(.callout, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                LabeledContent(L("Spread or pinch two fingers"), value: L("Full Screen"))
            }
        }
        .formStyle(.grouped)
    }
}
