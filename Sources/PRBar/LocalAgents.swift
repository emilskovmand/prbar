import Foundation

/// Reads running Claude Code sessions from ~/.claude/sessions/<pid>.json and
/// follows each session's transcript incrementally for PR links and context.
final class LocalAgents {
    private let claudeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")

    /// What we have learned from a transcript so far; only appended bytes are read on later polls.
    private struct TranscriptState {
        var path: URL
        var offset: UInt64 = 0
        var prRepo: String?
        var prNumber: Int?
        var title: String?
        var lastPrompt: String?
        var awaySummary: String?
        var cwd: String?
        var lastTimestamp: Date?
    }

    private var transcripts: [String: TranscriptState] = [:]
    private var branchCache: [String: (branch: String?, at: Date)] = [:]

    private struct SessionFile: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String?
        let status: String?
        let kind: String?
        let entrypoint: String?
        let statusUpdatedAt: Double?
    }

    func poll() -> [Agent] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var agents: [Agent] = []
        var seen = Set<String>()

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let s = try? JSONDecoder().decode(SessionFile.self, from: data),
                  isAlive(s.pid) else { continue }
            seen.insert(s.sessionId)

            let t = updateTranscript(for: s.sessionId)
            let cwd = t?.cwd ?? s.cwd
            let branch = currentBranch(in: cwd)
            let statusAt = s.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }

            agents.append(Agent(
                id: s.sessionId,
                kind: .local,
                source: Self.source(for: s.entrypoint),
                name: t?.title ?? s.name ?? s.sessionId,
                state: Self.state(for: s.status),
                detail: t?.awaySummary ?? t?.lastPrompt.map { "› \($0)" },
                lastActivity: [t?.lastTimestamp, statusAt].compactMap { $0 }.max(),
                prRepo: t?.prRepo,
                prNumber: t?.prNumber,
                branches: branch.map { [$0] } ?? [],
                ticket: ticketID(in: (cwd as NSString).lastPathComponent) ?? branch.flatMap(ticketID(in:)),
                openURL: nil,
                resumeCommand: "cd \(shellQuote(cwd)) && claude --resume \(s.sessionId)"
            ))
        }
        transcripts = transcripts.filter { seen.contains($0.key) }
        return agents
    }

    /// Claude Desktop and IDE sessions run the same CLI and register here too; label them by entrypoint.
    private static func source(for entrypoint: String?) -> String {
        switch entrypoint {
        case nil, "cli": return "CLI"
        case "claude-desktop", "desktop", "local-agent": return "Desktop"
        case "claude-vscode": return "VS Code"
        case let e? where e.hasPrefix("sdk"): return "SDK"
        case let e?: return e
        }
    }

    private static func state(for status: String?) -> AgentState {
        switch status {
        case "busy": return .working
        case "idle", nil: return .idle
        default: return .needsYou   // needs_input, waiting, blocked, permission…
        }
    }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Transcript tailing

    private func updateTranscript(for sessionId: String) -> TranscriptState? {
        if transcripts[sessionId] == nil, let path = findTranscript(sessionId) {
            transcripts[sessionId] = TranscriptState(path: path)
        }
        guard var t = transcripts[sessionId],
              let handle = try? FileHandle(forReadingFrom: t.path) else { return transcripts[sessionId] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < t.offset { t = TranscriptState(path: t.path) }  // rewritten
        guard size > t.offset else { return t }
        try? handle.seek(toOffset: t.offset)
        guard let chunk = try? handle.readToEnd() else { return t }

        // Only consume complete lines; a partial last line is picked up next poll.
        guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else { return t }
        let complete = chunk[chunk.startIndex...lastNewline]
        t.offset += UInt64(complete.count)

        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let cwd = obj["cwd"] as? String { t.cwd = cwd }
            if let ts = parseISO(obj["timestamp"] as? String) { t.lastTimestamp = ts }
            switch obj["type"] as? String {
            case "pr-link":
                t.prNumber = obj["prNumber"] as? Int
                t.prRepo = obj["prRepository"] as? String
            case "ai-title":
                t.title = obj["aiTitle"] as? String
            case "custom-title":
                t.title = (obj["customTitle"] as? String) ?? t.title
            case "last-prompt":
                t.lastPrompt = (obj["lastPrompt"] as? String).map(oneLine)
            case "user":
                // A new prompt makes any earlier recap stale.
                if (obj["message"] as? [String: Any])?["content"] is String { t.awaySummary = nil }
            case "system":
                if obj["subtype"] as? String == "away_summary", let c = obj["content"] as? String {
                    t.awaySummary = oneLine(c)
                        .replacingOccurrences(of: #"\s*\(disable recaps in /config\)\s*$"#, with: "", options: .regularExpression)
                }
            default: break
            }
        }
        transcripts[sessionId] = t
        return t
    }

    private func findTranscript(_ sessionId: String) -> URL? {
        let projects = claudeDir.appendingPathComponent("projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy
            .map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func currentBranch(in cwd: String) -> String? {
        if let c = branchCache[cwd], -c.at.timeIntervalSinceNow < 30 { return c.branch }
        let out = (try? Shell.run(["git", "branch", "--show-current"], cwd: cwd, timeout: 5))
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (out?.isEmpty ?? true) ? nil : out
        branchCache[cwd] = (branch, Date())
        return branch
    }
}

func oneLine(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
