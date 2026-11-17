import Foundation
import Security

/// API keys live in the macOS Keychain, never in preferences or files.
enum KeyStore {
    private static let service = "com.mttechnologies.studyoplayer.apikey"

    static func save(_ key: String, for account: String) -> Bool {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// ChatGPT (OpenAI) and Gemini (Google) over their HTTPS APIs, with the user's own key.
enum CloudAI {
    struct Turn { let fromUser: Bool; let text: String }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral // no cookies or cache left on disk
        // Longest silence allowed while answering. Reasoning models (GPT-5, Gemini Pro) can think
        // well over 20 s before the first word, especially with an image, so this is generous;
        // quick calls (checking a key, listing models) set their own short limit.
        config.timeoutIntervalForRequest = 90
        return URLSession(configuration: config)
    }()

    /// Limit for the quick calls that only check a key or list models.
    private static let quickTimeout: TimeInterval = 15

    static func keyPage(for kind: AIProvider.Kind) -> URL? {
        switch kind {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .geminiAPI: return URL(string: "https://aistudio.google.com/apikey")
        default: return nil
        }
    }

    private static func request(_ url: String, kind: AIProvider.Kind, key: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: url) else { throw AIError("Bad address.") }
        var req = URLRequest(url: url)
        if body == nil { req.timeoutInterval = quickTimeout } // GET calls are the quick ones
        // The key always travels in a header, never in the address.
        if kind == .openai {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private static func errorMessage(_ data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let message = err["message"] as? String {
            return String(message.prefix(300))
        }
        return "The service returned an error (HTTP \(status))."
    }

    /// Checks the key and returns the model to use. Throws with the service's own message if the key is rejected.
    static func validate(kind: AIProvider.Kind, key: String) async throws -> String {
        if kind == .openai {
            let (data, response) = try await session.data(for: request("https://api.openai.com/v1/models", kind: kind, key: key))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw AIError(errorMessage(data, status: status)) }
            let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
            // The key works; the model actually used is picked per question (see openAILadder).
            return ids.first { $0.hasPrefix("gpt-") } ?? "gpt-4o"
        } else {
            let (data, response) = try await session.data(for: request(
                "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200", kind: kind, key: key))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw AIError(errorMessage(data, status: status)) }
            let models = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? [])
                .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
            return newestGeminiFlash(models) ?? "gemini-3.8-flash"
        }
    }

    /// The last model list, per key (a hash of it, never the key itself) and kept for an hour.
    @MainActor private static var geminiListCache: (keyHash: Int, at: Date, models: [String])?

    /// Every Gemini text model this key can use, strongest first: newest version first, and
    /// within a version Pro, then Flash, then Flash-Lite. Used to step down when one model has
    /// no free quota left or has been retired.
    @MainActor static func geminiLadder(key: String) async -> [String] {
        if let cached = geminiListCache, cached.keyHash == key.hashValue,
           Date().timeIntervalSince(cached.at) < 3600, !cached.models.isEmpty {
            return cached.models
        }
        guard let req = try? request("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
                                     kind: .geminiAPI, key: key),
              let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let names = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? [])
            .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
            .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        let tiers = ["-pro": 0, "-flash": 1, "-flash-lite": 2]
        var ranked: [(name: String, version: Double, tier: Int)] = []
        for name in names where name.hasPrefix("gemini-") {
            // Longest suffix first, so "-flash-lite" is not mistaken for "-flash".
            for (suffix, tier) in tiers.sorted(by: { $0.key.count > $1.key.count }) where name.hasSuffix(suffix) {
                if let version = Double(name.dropFirst("gemini-".count).dropLast(suffix.count)) {
                    ranked.append((name, version, tier))
                }
                break
            }
        }
        ranked.sort { $0.version != $1.version ? $0.version > $1.version : $0.tier < $1.tier }
        let models = Array(ranked.map(\.name).prefix(8))
        geminiListCache = (key.hashValue, Date(), models)
        return models
    }

    @MainActor private static var openAIListCache: (keyHash: Int, at: Date, models: [String])?

    /// The ChatGPT models this key can use, strongest first (up to 6). Ranked by OpenAI's own
    /// order when Codex's model list is on this Mac, otherwise by version number, with the
    /// smaller "mini" and "nano" models last.
    @MainActor static func openAILadder(key: String) async -> [String] {
        if let cached = openAIListCache, cached.keyHash == key.hashValue,
           Date().timeIntervalSince(cached.at) < 3600, !cached.models.isEmpty {
            return cached.models
        }
        guard let req = try? request("https://api.openai.com/v1/models", kind: .openai, key: key),
              let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let ids = Set(((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String })
        let skip = ["audio", "realtime", "tts", "transcribe", "image", "search", "embedding", "instruct", "moderation"]
        // OpenAI's order, for the models it marks as available in the API.
        var ranked = CodexModels.entries().filter { $0.inAPI && ids.contains($0.slug) }.map(\.slug)
        // Then any other chat model, newest version first.
        func version(_ id: String) -> Double {
            Double(id.dropFirst(4).prefix { $0.isNumber || $0 == "." }) ?? 0
        }
        func size(_ id: String) -> Int { id.contains("nano") ? 2 : (id.contains("mini") ? 1 : 0) }
        let others = ids.filter { id in
            id.hasPrefix("gpt-") && !ranked.contains(id) && !skip.contains { id.contains($0) }
                && id.range(of: #"-20\d\d-"#, options: .regularExpression) == nil // dated snapshots
        }.sorted {
            (size($0), -version($0), $0.count, $0) < (size($1), -version($1), $1.count, $1)
        }
        ranked += others
        let models = Array(ranked.prefix(6))
        openAIListCache = (key.hashValue, Date(), models)
        return models
    }

    /// A readable model name for notes in the chat: "gemini-3.8-flash-lite" → "Gemini 3.8 Flash Lite".
    static func displayName(_ id: String) -> String {
        if let entry = CodexModels.entries().first(where: { $0.slug == id }) { return entry.name }
        let words = id.split(separator: "-").map(String.init)
        guard let first = words.first else { return id }
        if first.lowercased() == "gpt", words.count > 1 {
            return (["GPT-" + words[1]] + words.dropFirst(2).map { $0.capitalized }).joined(separator: " ")
        }
        return words.map { $0.first?.isNumber == true ? $0 : $0.capitalized }.joined(separator: " ")
    }

    /// Picks the newest general "flash" model by its version number, so the choice keeps up
    /// when Google retires a model. Falls back to "flash-lite", then to any flash model.
    static func newestGeminiFlash(_ models: [String]) -> String? {
        func version(_ name: String, suffix: String) -> Double? {
            guard name.hasPrefix("gemini-"), name.hasSuffix(suffix) else { return nil }
            return Double(name.dropFirst("gemini-".count).dropLast(suffix.count))
        }
        for suffix in ["-flash", "-flash-lite"] {
            let ranked = models.compactMap { name in version(name, suffix: suffix).map { (name, $0) } }
            if let best = ranked.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        return models.filter { $0.contains("flash") && !$0.contains("image") && !$0.contains("tts") && !$0.contains("audio") }
            .sorted().last
    }

    /// Sends the question (with the frame, if any) and streams the answer piece by piece.
    static func ask(kind: AIProvider.Kind, key: String, model: String, system: String, history: [Turn],
                    question: String, frameJPEG: Data?, onText: @escaping @MainActor (String) -> Void) async throws {
        let req: URLRequest
        if kind == .openai {
            var messages: [[String: Any]] = [["role": "system", "content": system]]
            for turn in history { messages.append(["role": turn.fromUser ? "user" : "assistant", "content": turn.text]) }
            var content: [[String: Any]] = [["type": "text", "text": question]]
            if let frameJPEG {
                content.append(["type": "image_url",
                                "image_url": ["url": "data:image/jpeg;base64," + frameJPEG.base64EncodedString()]])
            }
            messages.append(["role": "user", "content": content])
            req = try request("https://api.openai.com/v1/chat/completions", kind: kind, key: key,
                              body: ["model": model, "messages": messages, "stream": true])
        } else {
            var contents: [[String: Any]] = history.map {
                ["role": $0.fromUser ? "user" : "model", "parts": [["text": $0.text]]]
            }
            var parts: [[String: Any]] = []
            if let frameJPEG {
                parts.append(["inline_data": ["mime_type": "image/jpeg", "data": frameJPEG.base64EncodedString()]])
            }
            parts.append(["text": question])
            contents.append(["role": "user", "parts": parts])
            let safeModel = model.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? model
            req = try request("https://generativelanguage.googleapis.com/v1beta/models/\(safeModel):streamGenerateContent?alt=sse",
                              kind: kind, key: key,
                              body: ["contents": contents, "systemInstruction": ["parts": [["text": system]]]])
        }

        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 4000 { break } }
            throw AIError(errorMessage(data, status: status))
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var piece = ""
            if kind == .openai {
                if let delta = (obj["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] {
                    piece = delta["content"] as? String ?? ""
                }
            } else if let content = (obj["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any] {
                piece = (content["parts"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            }
            if !piece.isEmpty { await onText(piece) }
        }
    }
}

/// One saved conversation about one video.
struct ChatSession: Codable, Identifiable {
    struct Line: Codable {
        var user: Bool
        var text: String
        var timeMs: Double?
    }
    var id = UUID()
    var videoPath: String
    var videoName: String
    var updated: Date
    var lines: [Line]

    var title: String { lines.first(where: { $0.user })?.text ?? videoName }
}

/// Saved chats, kept only on this Mac in a file readable by this user alone.
enum ChatStore {
    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("StudyO Player", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("chats.json")
    }

    static func load() -> [ChatSession] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChatSession].self, from: data)) ?? []
    }

    /// Writes happen in order on a background queue, so saving never stalls the interface.
    private static let writer = DispatchQueue(label: "studyoplayer.chats", qos: .utility)

    static func save(_ sessions: [ChatSession]) {
        let snapshot = Array(sessions.prefix(300))
        writer.async {
            guard let url = fileURL else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Waits for pending writes (called when the app quits).
    static func flush() { writer.sync {} }
}
