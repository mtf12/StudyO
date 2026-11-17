import AppKit
import SwiftUI

/// The instructor panel: pick an AI, connect it once, then chat about the video.
struct AISidebar: View {
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var lang: Lang
    @FocusState private var inputFocused: Bool
    /// Extra space at the top so the header clears the window's close/minimise buttons.
    var topInset: CGFloat = 16

    private let quickPrompts: [(String, String)] = [
        ("eye", "What is on screen right now?"),
        ("text.bubble", "Explain this scene"),
        ("character.cursor.ibeam", "Read the text on screen"),
    ]

    private var connected: Bool { ai.isConnected(ai.selected) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                if ai.showHistory {
                    HistoryList().transition(.opacity)
                } else if let p = ai.selected, p.available, connected {
                    chat
                } else if let p = ai.selected, p.available {
                    ConnectScreen(provider: p).id(p.id)
                } else {
                    unavailable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if connected && !ai.showHistory { inputBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .background(VisualEffect(material: .sidebar).ignoresSafeArea())
        .environment(\.layoutDirection, lang.direction)
        .animation(Theme.spring, value: connected)
        .animation(Theme.spring, value: ai.selectedID)
        .animation(Theme.spring, value: ai.showHistory)
        .task { await ai.detect() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text(L("Study with your AI")).font(.system(size: 20, weight: .bold)).lineLimit(1)
                Spacer()
                if ai.detecting { ProgressView().controlSize(.small) }
                headerButton(ai.showHistory ? "clock.fill" : "clock", help: L("Previous chats")) {
                    ai.showHistory.toggle()
                }
                .foregroundStyle(ai.showHistory ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                headerButton("square.and.pencil", help: L("New chat")) { withAnimation(Theme.spring) { ai.newChat() } }
            }
            providerMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, topInset)
        .padding(.bottom, 14)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var providerMenu: some View {
        Menu {
            Picker("", selection: $ai.selectedID) {
                ForEach(ai.providers) { p in
                    Text(p.name + (p.available ? "" : " — " + L(p.detail))).tag(p.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(L("Look again for AIs on this Mac")) { Task { await ai.detect(force: true) } }
            if connected {
                Button(L("Disconnect")) { ai.disconnect() }
            }
        } label: {
            HStack(spacing: 10) {
                ProviderGlyph(kind: ai.selected?.kind, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ai.selected?.name ?? L("Choose an AI"))
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(connected ? Color.green : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                        Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var statusLine: String {
        guard let p = ai.selected else { return L("Nothing installed yet") }
        if !p.available { return L(p.detail) }
        if !connected { return L("Not connected") }
        if let plan = ai.accountPlan[p.connectKey], !plan.isEmpty { return L("Connected") + " · " + plan }
        return L("Connected")
    }

    // MARK: States

    private var unavailable: some View {
        VStack(spacing: 14) {
            ProviderGlyph(kind: ai.selected?.kind, size: 52).opacity(0.7)
            Text(L(ai.selected?.hint ?? "Install Claude Code, then press refresh."))
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if ai.selected?.notRunning == true {
                Button(L("Start Ollama")) { ai.startOllama() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(28)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if ai.messages.isEmpty { welcome.transition(.opacity) }
                    ForEach(ai.messages) { m in
                        MessageRow(message: m).equatable()
                            .id(m.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            .onChange(of: ai.messages.count) { _, _ in
                withAnimation(Theme.spring) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: ai.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Ask about this moment"))
                    .font(.system(size: 17, weight: .semibold))
                Text(L("Pause on anything and ask. Your instructor sees the frame you are watching."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(quickPrompts, id: \.1) { icon, text in
                    Button { ai.send(L(text)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 18)
                            Text(L(text)).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!player.hasMedia || ai.busy)
                    .opacity(player.hasMedia ? 1 : 0.5)
                }
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(player.hasMedia ? L("Ask about this moment…") : L("Open a video, then ask…"),
                      text: $ai.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { ai.send() }
                .padding(.leading, 12).padding(.vertical, 8)
            Button {
                if ai.busy { ai.cancel() } else { ai.send() }
            } label: {
                Image(systemName: ai.busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 26, height: 26)
                    .background(sendEnabled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.12)),
                                in: Circle())
                    .foregroundStyle(.white.opacity(sendEnabled ? 1 : 0.5))
            }
            .buttonStyle(PressableStyle())
            .disabled(!sendEnabled)
            .padding(.trailing, 5).padding(.bottom, 4)
            .help(ai.busy ? L("Stop") : L("Send"))
        }
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(inputFocused ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .animation(.easeOut(duration: 0.15), value: sendEnabled)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var sendEnabled: Bool {
        ai.busy || !ai.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - AI icons

/// The icon of an AI. Uses the real app icon when that AI's app is installed on this Mac,
/// otherwise a simple mark in the brand's colour.
struct ProviderGlyph: View {
    let kind: AIProvider.Kind?
    var size: CGFloat = 30

    private static var cache: [String: NSImage] = [:]

    private static func appIcon(for kind: AIProvider.Kind?) -> NSImage? {
        let apps: [String]
        switch kind {
        case .claude: apps = ["/Applications/Claude.app"]
        case .openai, .codex: apps = ["/Applications/ChatGPT.app"]
        case .ollama: apps = ["/Applications/Ollama.app"]
        case .geminiAPI, .gemini: apps = ["/Applications/Gemini.app", "/Applications/Google Gemini.app"]
        case nil: apps = []
        }
        for path in apps where FileManager.default.fileExists(atPath: path) {
            if let cached = cache[path] { return cached }
            let icon = NSWorkspace.shared.icon(forFile: path)
            cache[path] = icon
            return icon
        }
        return nil
    }

    var body: some View {
        if let icon = Self.appIcon(for: kind) {
            Image(nsImage: icon)
                .resizable().interpolation(.high)
                .frame(width: size * 1.18, height: size * 1.18) // app icons carry their own margin
                .frame(width: size, height: size)
        } else {
            fallback
                .frame(width: size, height: size)
                .background(tile, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        }
    }

    private var tile: AnyShapeStyle {
        switch kind {
        case .claude: return AnyShapeStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
        case .openai, .codex: return AnyShapeStyle(Color(white: 0.08))
        case .geminiAPI, .gemini: return AnyShapeStyle(Color(white: 0.11))
        case .ollama: return AnyShapeStyle(Color(white: 0.95))
        case nil: return AnyShapeStyle(Theme.accentGradient)
        }
    }

    @ViewBuilder private var fallback: some View {
        switch kind {
        case .claude:
            Image(systemName: "sun.max.fill").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
        case .openai, .codex:
            Image(systemName: "circle.hexagonpath.fill").font(.system(size: size * 0.52, weight: .medium)).foregroundStyle(.white)
        case .geminiAPI, .gemini:
            Image(systemName: "sparkle").font(.system(size: size * 0.56, weight: .bold))
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.61, green: 0.45, blue: 0.95),
                             Color(red: 0.85, green: 0.40, blue: 0.47)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        case .ollama:
            Image(systemName: "cube.fill").font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.black)
        case nil:
            Image(systemName: "sparkles").font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

// MARK: - Connect

/// Shown until the selected AI is connected: one clear action, nothing else.
struct ConnectScreen: View {
    @EnvironmentObject var ai: AIModel
    let provider: AIProvider

    private var name: String { provider.kind == .ollama ? "Ollama" : provider.name }

    private var subtitle: String {
        if provider.needsKey { return L("Paste your API key. It is kept in your Mac's Keychain.") }
        if provider.needsSignIn { return L("Sign in once, then ask about any moment of your video.") }
        return L("Runs on this Mac. No account needed.")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            ProviderGlyph(kind: provider.kind, size: 68)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                .padding(.bottom, 18)
            Text(L("Connect") + " " + name)
                .font(.system(size: 19, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 26)

            VStack(alignment: .leading, spacing: 12) {
                feature("eye", L("Sees the frame you are watching"))
                feature("captions.bubble", L("Reads the subtitles around it"))
                feature("hand.raised", L("Only runs when you ask"))
            }
            .padding(.top, 24)
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                if provider.needsKey && !ai.connecting {
                    SecureField(L("API key"), text: $ai.apiKeyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline))
                        .onSubmit { ai.connect() }
                }
                if ai.connecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(ai.connectStatus ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 38)
                    HStack(spacing: 14) {
                        if let url = ai.signInURL {
                            Button(L("Open sign-in page")) { NSWorkspace.shared.open(url) }
                        }
                        Button(L("Cancel")) { ai.cancelConnect() }
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                    .transition(.opacity)
                } else {
                    Button { ai.connect() } label: {
                        Text(provider.needsSignIn ? L("Sign In") : L("Connect"))
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    if let error = ai.connectError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    } else if provider.needsKey, let page = CloudAI.keyPage(for: provider.kind) {
                        Button(L("Get an API key")) { NSWorkspace.shared.open(page) }
                            .buttonStyle(.link).font(.system(size: 12))
                    } else if provider.needsSignIn {
                        Text(L("Uses the account you already have in") + " " + name + ".")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .animation(Theme.spring, value: ai.connecting)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(text).font(.system(size: 13))
        }
    }
}

// MARK: - Previous chats

struct HistoryList: View {
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var player: PlayerModel

    private static let dates: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        if ai.sessions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text(L("Your chats will appear here."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(28)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text(L("Previous chats"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.bottom, 2)
                    ForEach(ai.sessions) { session in
                        Button { withAnimation(Theme.spring) { ai.openSession(session) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                HStack(spacing: 5) {
                                    Image(systemName: "film").font(.system(size: 9))
                                    Text(session.videoName).lineLimit(1).truncationMode(.middle)
                                    Text("·")
                                    Text(Self.dates.localizedString(for: session.updated, relativeTo: Date()))
                                        .fixedSize()
                                }
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            Button(L("Delete"), role: .destructive) { withAnimation(Theme.spring) { ai.deleteSession(session) } }
                        }
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Chat bubbles

/// Message bubble with a small tail, like Messages.
struct BubbleShape: Shape {
    /// True: tail at the bottom of the trailing side (your messages). False: leading side (replies).
    var tailOnTrailing: Bool
    static let tail: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let t = Self.tail
        let radius = min(17, rect.height / 2)
        let body = CGRect(x: rect.minX + (tailOnTrailing ? 0 : t), y: rect.minY, width: rect.width - t, height: rect.height)
        var path = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        var tail = Path()
        let y = rect.maxY
        if tailOnTrailing {
            let x = body.maxX
            tail.move(to: CGPoint(x: x - 1, y: y - 15))
            tail.addQuadCurve(to: CGPoint(x: x + t, y: y), control: CGPoint(x: x, y: y - 3))
            tail.addQuadCurve(to: CGPoint(x: x - 12, y: y - 3), control: CGPoint(x: x - 3, y: y + 0.5))
        } else {
            let x = body.minX
            tail.move(to: CGPoint(x: x + 1, y: y - 15))
            tail.addQuadCurve(to: CGPoint(x: x - t, y: y), control: CGPoint(x: x, y: y - 3))
            tail.addQuadCurve(to: CGPoint(x: x + 12, y: y - 3), control: CGPoint(x: x + 3, y: y + 0.5))
        }
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}

/// Three dots that bounce while the AI is working.
struct TypingDots: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .phaseAnimator([false, true]) { view, up in
                        view.offset(y: up ? -2.5 : 1.5).opacity(up ? 1 : 0.35)
                    } animation: { _ in .easeInOut(duration: 0.45).delay(Double(i) * 0.14) }
            }
        }
        .frame(height: 17)
    }
}

/// One chat bubble. Your side shows only your text (the frame is sent to the AI, not shown).
/// Depends on its message only (not on the player, which changes several times a second), and is
/// Equatable, so while an answer streams in only the bubble being written is redrawn.
struct MessageRow: View, Equatable {
    let message: ChatMessage

    static func == (a: MessageRow, b: MessageRow) -> Bool { a.message == b.message }

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 3) {
                Text(message.text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                    .padding(.leading, 13)
                    .padding(.trailing, 13 + BubbleShape.tail)
                    .background(BubbleShape(tailOnTrailing: true).fill(Theme.userBubble)
                        .flipsForRightToLeftLayoutDirection(true))
                if let t = message.timeMs {
                    Button { PlayerModel.shared.seek(toMs: t) } label: {
                        Label(formatTime(t), systemImage: "play.circle")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    }
                    .buttonStyle(PressableStyle()).foregroundStyle(.tertiary)
                    .padding(.trailing, BubbleShape.tail + 4)
                    .help(L("Jump back to this moment"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if message.status != nil && message.text.isEmpty {
                    TypingDots()
                } else {
                    Text(rendered(message.text))
                        .font(.system(size: 13.5))
                        .textSelection(.enabled)
                        .foregroundStyle(message.isError ? Color.red.opacity(0.9) : Color.primary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 8)
            .padding(.trailing, 13)
            .padding(.leading, 13 + BubbleShape.tail)
            .background(BubbleShape(tailOnTrailing: false).fill(Theme.replyBubble)
                .flipsForRightToLeftLayoutDirection(true))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 24)
        }
    }

    /// Renders bold/italic/code from the answer. Security: links are removed so an answer can
    /// never plant a clickable address in the chat.
    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var result = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in result.runs where run.link != nil {
            result[run.range].link = nil
        }
        return result
    }
}
