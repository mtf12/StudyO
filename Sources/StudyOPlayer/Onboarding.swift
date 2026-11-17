import AppKit
import SwiftUI

/// The welcome tour shown on first launch (and again from Help → Welcome Tour):
/// a few pages with Skip, Back and Next that explain what the app does and how the AIs work.
struct OnboardingView: View {
    @EnvironmentObject var lang: Lang
    /// Called when the tour ends, by Skip or by the last button.
    let finish: () -> Void
    @State private var page = 0

    private let pageCount = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < pageCount - 1 {
                    Button(L("Skip"), action: finish)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .frame(height: 22)
            .padding(.horizontal, 22).padding(.top, 16)

            Group {
                switch page {
                case 0: welcome
                case 1: player
                case 2: instructor
                case 3: aiChoices
                default: ready
                }
            }
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)

            footer
        }
        .frame(width: 600, height: 540)
        .background(VisualEffect(material: .sidebar).ignoresSafeArea())
        .environment(\.layoutDirection, lang.direction)
        .animation(Theme.spring, value: page)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(L("Back")) { page -= 1 }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(page > 0 ? 1 : 0)
                .disabled(page == 0)
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.18)))
                        .frame(width: i == page ? 18 : 7, height: 7)
                }
            }
            Spacer()
            Button {
                if page < pageCount - 1 { page += 1 } else { finish() }
            } label: {
                Text(page < pageCount - 1 ? L("Next") : L("Start Watching"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 26).padding(.bottom, 22).padding(.top, 10)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: Theme.accent.opacity(0.45), radius: 24, y: 10)
            Text(L("Welcome to StudyO Player"))
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text(L("A video player made for studying, with an AI instructor beside the video that sees what you are watching and answers your questions."))
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var player: some View {
        PageLayout(icon: "play.rectangle.fill", title: L("Plays practically everything")) {
            Feature(icon: "film.stack", text: L("MKV, MP4, MOV, AVI, WebM, FLV, WMV, TS and more, with no extra downloads."))
            Feature(icon: "captions.bubble", text: L("Subtitle files (.srt, .ass, .vtt), multiple audio tracks and playback speeds."))
            Feature(icon: "arrow.counterclockwise", text: L("Picks up where you stopped in each video."))
            Feature(icon: "hand.draw", text: L("Drop a video anywhere in the window. On a MacBook, use the Touch Bar and trackpad gestures."))
        }
    }

    private var instructor: some View {
        PageLayout(icon: "sparkles", title: L("Your AI instructor")) {
            Feature(icon: "eye", text: L("Pause on anything and ask: the AI sees the frame on screen and reads the nearby subtitles."))
            Feature(icon: "text.bubble", text: L("Ask it to explain a scene, read the text on screen, or go deeper into the lesson."))
            Feature(icon: "clock.arrow.circlepath", text: L("Each video keeps its own chat, and it comes back when you open the video again."))
            Feature(icon: "sidebar.left", text: L("Show or hide the panel any time, and put it on the left or the right."))
        }
    }

    private var aiChoices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(L("Choosing an AI")).font(.system(size: 20, weight: .bold))
            } icon: {
                Image(systemName: "cpu").foregroundStyle(Theme.accent)
            }
            AIGroup(title: L("Free"), tint: .green, items: [
                (L("Gemini (API)"), L("Get a free key from Google AI Studio. The app starts with the strongest model and moves to the next one by itself when a model's free quota runs out.")),
                (L("ChatGPT"), L("Sign in with your ChatGPT account through Codex. Works on the free Codex plan.")),
                (L("Ollama"), L("Runs free models on your own Mac, no internet needed.")),
            ])
            AIGroup(title: L("With your own paid account"), tint: Theme.accent, items: [
                (L("ChatGPT (API)"), L("Your own OpenAI API key; you pay OpenAI for what you use.")),
                (L("Claude"), L("Through Claude Code, signed in with your Claude plan.")),
            ])
            Text(L("Keys stay in your Mac's Keychain. You can change the AI any time from the top of the panel."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ready: some View {
        PageLayout(icon: "checkmark.circle.fill", title: L("You're all set")) {
            Feature(icon: "space", text: L("Space plays and pauses, the arrow keys skip back and forward, F goes full screen."))
            Feature(icon: "gearshape", text: L("Language, panel side and playback options are in Settings (⌘,)."))
            Feature(icon: "questionmark.circle", text: L("See this tour again any time from the Help menu."))
        }
    }
}

// MARK: - Building blocks

private struct PageLayout<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.4), radius: 16, y: 8)
            Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: 460, alignment: .leading)
        }
    }
}

private struct Feature: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(text).font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AIGroup: View {
    let title: String
    let tint: Color
    let items: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tint.opacity(0.15), in: Capsule())
            ForEach(items, id: \.0) { name, detail in
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
