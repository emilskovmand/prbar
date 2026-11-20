import AppKit

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
        /// Files edited in a git checkout, by checkout root.
        var editedFiles: [String: Set<String>] = [:]
    }

    private var transcripts: [String: TranscriptState] = [:]
    private var branchCache: [String: (branch: String?, at: Date)] = [:]
    private var changesCache: [String: (changes: Bool, at: Date)] = [:]
    private var hostCache: [Int32: (tty: String?, app: URL?)] = [:]
    private var subagentCache: [String: SubagentFile] = [:]
    private var seenSubagentFiles = Set<String>()

    private struct SessionFile: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String?
        let status: String?
        let kind: String?
        let entrypoint: String?
        let statusUpdatedAt: Double?
        /// Set when the chat moved to a background job; this process is then just a shell.
        let parkedJobId: String?
        /// A pre-started background session nobody has used yet.
        let spare: Bool?
    }

    func poll() -> [Agent] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var agents: [Agent] = []
        var seen = Set<String>()
        var seenPids = Set<Int32>()

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let s = try? JSONDecoder().decode(SessionFile.self, from: data),
                  isAlive(s.pid) else { continue }
            // The job shows up as its own session, so these would only add a row that isn't a chat.
            if s.parkedJobId != nil || s.spare == true { continue }
            seen.insert(s.sessionId)
            seenPids.insert(s.pid)

            let t = updateTranscript(for: s.sessionId)
            let cwd = t?.cwd ?? s.cwd
            let worktree = worktreeName(containing: cwd)
            // In a shared checkout the branch is whatever was last checked out there, which every
            // session in it would otherwise claim; only a worktree's branch is the session's own.
            let branch = worktree == nil ? nil : currentBranch(in: cwd)
            let statusAt = s.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            let host = hostCache[s.pid] ?? Self.host(of: s.pid)
            hostCache[s.pid] = host
            let subs = t.map { subagents(of: $0.path) } ?? ([], 0)

            agents.append(Agent(
                id: s.sessionId,
                kind: .local,
                source: claudeSource(for: s.entrypoint),
                name: t?.title ?? s.name ?? s.sessionId,
                state: Self.state(for: s.status),
                detail: t?.awaySummary ?? t?.lastPrompt.map { "› \($0)" },
                lastActivity: [t?.lastTimestamp, statusAt].compactMap { $0 }.max(),
                prRepo: t?.prRepo,
                prNumber: t?.prNumber,
                branches: branch.map { [$0] } ?? [],
                ticket: ticketID(in: (cwd as NSString).lastPathComponent) ?? branch.flatMap(ticketID(in:)),
                openURL: nil,
                resumeCommand: "cd \(shellQuote(cwd)) && claude --resume \(s.sessionId)",
                cwd: cwd,
                worktree: worktree,
                tty: host.tty,
                hostApp: host.app,
                hasCodeChanges: t.map { hasCodeChanges($0.editedFiles, sessionId: s.sessionId) } ?? false,
                subagents: subs.0,
                finishedSubagents: subs.1
            ))
        }
        subagentCache = subagentCache.filter { seenSubagentFiles.contains($0.key) }
        seenSubagentFiles = []
        transcripts = transcripts.filter { seen.contains($0.key) }
        hostCache = hostCache.filter { seenPids.contains($0.key) }
        changesCache = changesCache.filter { seen.contains($0.key) }
        return agents
    }

    private static func state(for status: String?) -> AgentState {
        switch status {
        case "busy": return .working
        // The turn ended with a background command running; the agent resumes when it exits.
        case "shell": return .watching
        case "idle", nil: return .idle
        default: return .needsYou   // needs_input, waiting, blocked, permission…
        }
    }

    /// The session's terminal device and the outermost app among its ancestors (iTerm, Cursor, Claude…).
    private static func host(of pid: Int32) -> (tty: String?, app: URL?) {
        func ps(_ field: String, _ pid: Int32) -> String? {
            (try? Shell.run(["ps", "-o", "\(field)=", "-p", "\(pid)"], timeout: 3))
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tty = ps("tty", pid).flatMap { $0.isEmpty || $0 == "??" ? nil : "/dev/" + $0 }

        var app: URL?
        var current = pid
        for _ in 0..<12 {
            guard let parent = ps("ppid", current).flatMap({ Int32($0) }), parent > 1 else { break }
            let comm = ps("comm", parent) ?? ""
            if let r = comm.range(of: ".app/") {
                app = URL(fileURLWithPath: String(comm[..<r.lowerBound]) + ".app")
            } else if comm.contains("/iTerm2/iTermServer") {
                // iTerm runs its shells under a server in Application Support, parented to launchd,
                // so the walk never reaches iTerm.app itself.
                app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
            }
            current = parent
        }
        return (tty, app)
    }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Transcript tailing

    private func updateTranscript(for sessionId: String) -> TranscriptState? {
        // Entering a worktree moves the transcript to that worktree's project folder, so look again once it's gone.
        let missing = transcripts[sessionId].map { !FileManager.default.fileExists(atPath: $0.path.path) } ?? true
        if missing, let path = findTranscript(sessionId) {
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
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                // Memory, plan and scratchpad files aren't code; only edits inside a git checkout count.
                for c in content where c["type"] as? String == "tool_use" && Self.editTools.contains(c["name"] as? String ?? "") {
                    guard let input = c["input"] as? [String: Any],
                          let file = (input["file_path"] ?? input["notebook_path"]) as? String,
                          let root = gitCheckoutRoot(containing: file) else { continue }
                    t.editedFiles[root, default: []].insert(file)
                }
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

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    private func findTranscript(_ sessionId: String) -> URL? {
        let projects = claudeDir.appendingPathComponent("projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy
            .map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Subagents

    /// What one subagent's files said the last time they changed.
    private struct SubagentFile {
        var metaAt: Date?
        var logAt: Date?
        var parentID: String?
        var name: String
        var type: String?
        var finished = false        // the meta file says so
        var ended = false           // its last message closed the turn
        var inTool = false          // its last message started a tool, which can run for minutes
        var startedAt: Date?
    }

    /// The session's subagents, from `<transcript>/subagents/agent-<id>.meta.json` and the transcript
    /// next to each. Returns the ones to draw and how many of the session's subagents have finished.
    private func subagents(of transcript: URL) -> ([Subagent], Int) {
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return ([], 0) }
        let now = Date()
        var all: [String: (file: SubagentFile, running: Bool)] = [:]

        for meta in files {
            let fileName = meta.lastPathComponent
            guard fileName.hasPrefix("agent-"), fileName.hasSuffix(".meta.json") else { continue }
            let id = String(fileName.dropFirst("agent-".count).dropLast(".meta.json".count))
            let log = dir.appendingPathComponent("agent-\(id).jsonl")
            let metaAt = (try? meta.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            let logValues = try? log.resourceValues(forKeys: Set(keys))
            let logAt = logValues?.contentModificationDate
            seenSubagentFiles.insert(log.path)

            var file = subagentCache[log.path]
            if file == nil || file?.metaAt != metaAt || file?.logAt != logAt {
                file = readSubagent(id: id, meta: meta, log: log, known: file)
                file?.metaAt = metaAt
                file?.logAt = logAt
                file?.startedAt = logValues?.creationDate ?? metaAt
                subagentCache[log.path] = file
            }
            guard let file else { continue }
            // A stopped subagent leaves no end marker, so one that has been quiet for longer than
            // a model reply or a tool call takes counts as stopped.
            let quiet = now.timeIntervalSince(logAt ?? metaAt ?? .distantPast)
            let running = !file.finished && !file.ended && quiet < (file.inTool ? 600 : 180)
            all[id] = (file, running)
        }

        // A subagent waiting on its own subagent writes nothing meanwhile, but is still running.
        for (id, entry) in all where entry.running {
            var parent = all[id]?.file.parentID
            var hops = 0
            while let p = parent, let e = all[p], hops < 8 {
                if !e.file.finished && !e.file.ended { all[p]?.running = true }
                parent = e.file.parentID
                hops += 1
            }
        }

        // Draw the running ones, the ones that finished in the last two minutes, and their parents.
        var shown = Set<String>()
        for (id, entry) in all where entry.running || now.timeIntervalSince(entry.file.logAt ?? .distantPast) < 120 {
            var current: String? = id
            var hops = 0
            while let c = current, all[c] != nil, hops < 8 {
                shown.insert(c)
                current = all[c]?.file.parentID
                hops += 1
            }
        }
        let subs = shown.compactMap { id -> Subagent? in
            guard let e = all[id] else { return nil }
            return Subagent(id: id, parentID: e.file.parentID, name: e.file.name, type: e.file.type,
                            running: e.running, startedAt: e.file.startedAt, lastActivity: e.file.logAt)
        }
        return (subs, all.values.filter { !$0.running }.count)
    }

    private func readSubagent(id: String, meta: URL, log: URL, known: SubagentFile?) -> SubagentFile {
        let m = (try? Data(contentsOf: meta)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let agentType = m["agentType"] as? String
        var name = known?.name ?? ""
        if let description = m["description"] as? String, !description.isEmpty {
            name = oneLine(description)
        } else if name.isEmpty {
            // No description: a skill running in a fork is named after the skill, anything else after its prompt.
            let skill = (try? Data(contentsOf: meta.deletingLastPathComponent().appendingPathComponent("agent-\(id).forked-skill.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["skillName"] as? String
            name = skill.map { "/" + $0 } ?? (m["name"] as? String) ?? Self.firstPrompt(in: log) ?? ""
        }
        // "/code-review /Users/me/development/app" → "/code-review app"; the folder is all that tells them apart.
        name = name.replacingOccurrences(of: #"(?:~|/Users/[^/\s]+)(?:/[^/\s`]+)*/([^/\s`]+)/?"#, with: "$1", options: .regularExpression)
        var file = SubagentFile(parentID: m["parentAgentId"] as? String,
                                name: name.isEmpty ? (agentType ?? "Subagent") : name,
                                type: agentType == "general-purpose" ? nil : agentType,
                                finished: m["finished"] as? Bool ?? false)
        if !file.finished, let last = Self.lastLine(of: log) {
            // Quotes inside message text are escaped, so these only match the message's own fields.
            file.ended = last.contains(#""stop_reason":"end_turn""#)
            file.inTool = last.contains(#""stop_reason":"tool_use""#)
        }
        return file
    }

    /// The end of the transcript's last complete line; enough for the fields that close a message.
    private static func lastLine(of log: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
        guard var tail = try? handle.readToEnd() else { return nil }
        // Drop a line that is still being written.
        guard let end = tail.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        tail = tail[tail.startIndex..<end]
        let start = tail.lastIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
        return String(decoding: tail[start...], as: UTF8.self)
    }

    /// The first line of the prompt the subagent was started with.
    private static func firstPrompt(in log: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 262_144),
              let end = data.firstIndex(of: UInt8(ascii: "\n")),
              let obj = try? JSONSerialization.jsonObject(with: data[data.startIndex..<end]) as? [String: Any],
              let message = obj["message"] as? [String: Any] else { return nil }
        let text = (message["content"] as? String)
            ?? (message["content"] as? [[String: Any]])?.lazy.compactMap { $0["text"] as? String }.first
        guard let line = text?.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        let short = line.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? nil : String(short.prefix(120))
    }

    /// Whether the session's work is still only on this Mac: a file it edited has uncommitted changes,
    /// or it edited in a worktree whose branch has commits on no remote. A shared checkout's unpushed
    /// commits could be anyone's, so there only the edited files count.
    private func hasCodeChanges(_ edited: [String: Set<String>], sessionId: String) -> Bool {
        guard !edited.isEmpty else { return false }
        if let c = changesCache[sessionId], -c.at.timeIntervalSinceNow < 15 { return c.changes }
        func git(_ args: [String], in root: String) -> String {
            (try? Shell.run(["git"] + args, cwd: root, timeout: 5))
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let changes = edited.contains { root, files in
            // A removed worktree took its changes with it.
            guard FileManager.default.fileExists(atPath: root) else { return false }
            if !git(["status", "--porcelain", "--"] + files.sorted(), in: root).isEmpty { return true }
            return worktreeName(containing: root) != nil
                && (Int(git(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: root)) ?? 0) > 0
        }
        changesCache[sessionId] = (changes, Date())
        return changes
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

/// Claude Desktop and IDE sessions run the same CLI and register here too; label them by entrypoint.
func claudeSource(for entrypoint: String?) -> String {
    switch entrypoint {
    case nil, "cli": return "CLI"
    case "claude-desktop", "desktop", "local-agent": return "Desktop"
    case "claude-vscode": return "VS Code"
    case let e? where e.hasPrefix("sdk"): return "SDK"
    case let e?: return e
    }
}

func oneLine(_ s: String) -> String {
    s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
