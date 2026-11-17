import Foundation

/// An AI found on this Mac that StudyO Player can talk to.
struct AIProvider: Identifiable, Hashable {
    enum Kind: String { case claude, openai, geminiAPI, codex, gemini, ollama }
    let id: String
    let kind: Kind
    let name: String
    /// English text; shown through L() so it follows a language change without a new search.
    let detail: String
    var execPath: String? = nil
    var model: String? = nil
    var vision = true
    var available = true
    var hint = ""
    var notRunning = false
    /// One connection per tool: all Ollama models share one.
    var connectKey: String { kind.rawValue }
    /// True when the tool has an account to sign in to.
    var needsSignIn: Bool { kind == .claude || kind == .codex }
    /// True when the AI is reached over the internet with the user's own API key.
    var needsKey: Bool { kind == .openai || kind == .geminiAPI }
}

enum AIDetector {
    static var searchDirs: [String] {
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/bin", "/usr/bin",
        ]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        return dirs
    }

    static func which(_ tool: String) -> String? {
        for dir in searchDirs {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path), isTrustedExecutable(path) { return path }
        }
        return nil
    }

    /// Security: only run a tool that is a real file owned by this user (or root) and that other
    /// users cannot overwrite, so a planted or tampered binary is never launched.
    static func isTrustedExecutable(_ path: String) -> Bool {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let owner = attrs[.ownerAccountID] as? NSNumber,
              let perms = attrs[.posixPermissions] as? NSNumber else { return false }
        let ownerOK = owner.uint32Value == getuid() || owner.uint32Value == 0
        return ownerOK && (perms.intValue & 0o002) == 0
    }

    /// Security: child tools get a small, known environment instead of everything the app has.
    static func childEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let keep: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL",
                                 "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
                                 "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "XDG_CONFIG_HOME"]
        let prefixes = ["ANTHROPIC_", "CLAUDE_CONFIG", "CLAUDE_CODE_USE_", "AWS_", "OPENAI_", "CODEX_",
                        "GEMINI_", "GOOGLE_"]
        var env = source.filter { key, _ in keep.contains(key) || prefixes.contains { key.hasPrefix($0) } }
        env["PATH"] = (searchDirs + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["TERM"] = "dumb"
        return env
    }

    /// Looks for every supported AI: CLI agents first, then local Ollama models.
    static func detect() async -> [AIProvider] {
        var found: [AIProvider] = []

        let claude = which("claude")
        found.append(AIProvider(
            id: "claude", kind: .claude, name: "Claude Code",
            detail: claude != nil ? "Sees the current frame" : "Not installed",
            execPath: claude, available: claude != nil,
            hint: "Install Claude Code, then press refresh."))

        // ChatGPT by normal sign-in: through OpenAI's own Codex tool, either installed on its own
        // or the copy that ships inside the ChatGPT app.
        let bundledCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        let codex = which("codex")
            ?? ((FileManager.default.isExecutableFile(atPath: bundledCodex) && isTrustedExecutable(bundledCodex)) ? bundledCodex : nil)
        if let codex {
            found.append(AIProvider(id: "codex", kind: .codex, name: "ChatGPT",
                                    detail: "Sees the current frame", execPath: codex))
        }
        // Cloud AIs by API key need nothing installed.
        found.append(AIProvider(id: "openai", kind: .openai, name: codex == nil ? "ChatGPT" : "ChatGPT · API",
                                detail: "Sees the current frame"))
        found.append(AIProvider(id: "geminiAPI", kind: .geminiAPI, name: "Gemini", detail: "Sees the current frame"))

        if let gemini = which("gemini") {
            found.append(AIProvider(id: "gemini", kind: .gemini, name: "Gemini CLI",
                                    detail: "Sees the current frame", execPath: gemini))
        }

        let ollamaBin = which("ollama")
        let ollamaInstalled = ollamaBin != nil
            || FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
        if ollamaInstalled {
            if let models = await ollamaModels() {
                if models.isEmpty {
                    found.append(AIProvider(
                        id: "ollama", kind: .ollama, name: "Ollama", detail: "No models downloaded",
                        execPath: ollamaBin, available: false,
                        hint: "Download a vision model in Terminal: ollama pull llava"))
                }
                for m in models {
                    found.append(AIProvider(
                        id: "ollama:\(m.name)", kind: .ollama, name: m.name,
                        detail: m.vision ? "Ollama · sees the current frame" : "Ollama · text only (no frame)",
                        execPath: ollamaBin, model: m.name, vision: m.vision))
                }
            } else {
                found.append(AIProvider(
                    id: "ollama", kind: .ollama, name: "Ollama", detail: "Installed, not running",
                    execPath: ollamaBin, available: false,
                    hint: "Ollama is installed but its server is not running.", notRunning: true))
            }
        }
        return found
    }

    // MARK: - Ollama

    static let ollamaBase = URL(string: "http://127.0.0.1:11434")!

    /// Returns nil when the Ollama server is not reachable.
    static func ollamaModels() async -> [(name: String, vision: Bool)]? {
        var req = URLRequest(url: ollamaBase.appendingPathComponent("api/tags"))
        req.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["models"] as? [[String: Any]] else { return nil }
        var result: [(String, Bool)] = []
        for item in list {
            guard let name = item["name"] as? String else { continue }
            result.append((name, await ollamaHasVision(name)))
        }
        return result
    }

    private static func ollamaHasVision(_ model: String) async -> Bool {
        var req = URLRequest(url: ollamaBase.appendingPathComponent("api/show"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let caps = obj["capabilities"] as? [String] {
            return caps.contains("vision")
        }
        let lower = model.lowercased()
        return ["llava", "vision", "gemma3", "qwen2.5vl", "minicpm", "moondream", "bakllava"]
            .contains { lower.contains($0) }
    }

    static func startOllama(binary: String?) {
        if let binary {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Ollama"]
            try? p.run()
        }
    }
}

/// Runs a command-line AI and streams its stdout line by line.
/// Cancelling (the Stop button, or the Swift task being cancelled) terminates the tool, even if
/// that happens before it has been launched.
final class ProcessRunner: @unchecked Sendable {
    private var process: Process?
    private var cancelled = false
    private let lock = NSLock()

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Output collected while the tool runs. Touched only on the runner's serial queue.
    private final class Streams: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }

    /// Returns (exit code, stderr text).
    func run(exe: String, args: [String], cwd: URL, stdin: Data? = nil,
             onLine: @escaping (String) -> Void) async throws -> (Int32, String) {
        try await withTaskCancellationHandler {
            try await launch(exe: exe, args: args, cwd: cwd, stdin: stdin, onLine: onLine)
        } onCancel: {
            self.cancel()
        }
    }

    private func launch(exe: String, args: [String], cwd: URL, stdin: Data?,
                        onLine: @escaping (String) -> Void) async throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = AIDetector.childEnvironment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input: Pipe? = stdin != nil ? Pipe() : nil
        p.standardInput = input ?? FileHandle.nullDevice

        // Reads and line splitting happen on one serial queue, so output is never reordered and
        // the last chunk read at exit cannot overtake one still being handled.
        let queue = DispatchQueue(label: "studyoplayer.proc")
        let streams = Streams()

        func drain(final: Bool) {
            while let nl = streams.out.firstIndex(of: 0x0A) {
                let lineData = streams.out.subdata(in: streams.out.startIndex..<nl)
                streams.out.removeSubrange(streams.out.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) { onLine(line) }
            }
            if final, !streams.out.isEmpty, let line = String(data: streams.out, encoding: .utf8) {
                streams.out.removeAll()
                onLine(line)
            }
        }

        out.fileHandleForReading.readabilityHandler = { h in
            queue.sync {
                let d = h.availableData
                if d.isEmpty { return }
                streams.out.append(d)
                drain(final: false)
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            queue.sync {
                let d = h.availableData
                if !d.isEmpty { streams.err.append(d) }
            }
        }

        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                let errText: String = queue.sync {
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    streams.out.append(out.fileHandleForReading.readDataToEndOfFile())
                    drain(final: true)
                    streams.err.append(err.fileHandleForReading.readDataToEndOfFile())
                    return String(data: streams.err, encoding: .utf8) ?? ""
                }
                cont.resume(returning: (proc.terminationStatus, errText))
            }
            lock.lock()
            if cancelled {
                lock.unlock()
                p.terminationHandler = nil
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: CancellationError())
                return
            }
            do {
                try p.run()
                process = p
                lock.unlock()
                if let input, let stdin {
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? input.fileHandleForWriting.write(contentsOf: stdin)
                        try? input.fileHandleForWriting.close()
                    }
                }
            } catch {
                lock.unlock()
                p.terminationHandler = nil
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
}
