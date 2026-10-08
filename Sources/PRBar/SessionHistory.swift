import Foundation

/// Indexes recent Claude Code transcripts (including sessions that have ended) so a PR can
/// open the latest chat that worked on it. Files are re-read only when they change.
final class SessionHistory {
    private let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    private let window: TimeInterval = 14 * 86400

    private struct Entry {
        let modified: Date
        let agent: Agent?
    }

    private var cache: [String: Entry] = [:]

    func poll() -> [Agent] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-window)
        var seen = Set<String>()
        var agents: [Agent] = []

        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified > cutoff else { continue }
                seen.insert(file.path)
                if let cached = cache[file.path], cached.modified == modified {
                    if let a = cached.agent { agents.append(a) }
                    continue
                }
                let agent = Self.parse(file, modified: modified)
                cache[file.path] = Entry(modified: modified, agent: agent)
                if let agent { agents.append(agent) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return agents
    }

    private static let markers = ["\"type\":\"pr-link\"", "\"type\":\"ai-title\"", "\"type\":\"custom-title\""]
        .map { Data($0.utf8) }

    /// Only lines carrying a marker are JSON-decoded; cwd and branch come from the last lines.
    private static func parse(_ file: URL, modified: Date) -> Agent? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let lines = data.split(separator: UInt8(ascii: "\n"))

        var prNumber: Int?, prRepo: String?, title: String?
        for line in lines where markers.contains(where: { line.range(of: $0) != nil }) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "pr-link": prNumber = obj["prNumber"] as? Int; prRepo = obj["prRepository"] as? String
            case "ai-title": title = obj["aiTitle"] as? String ?? title
            case "custom-title": title = obj["customTitle"] as? String ?? title
            default: break
            }
        }

        var cwd: String?, entrypoint: String?
        for line in lines.suffix(200).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let c = obj["cwd"] as? String else { continue }
            cwd = c
            entrypoint = obj["entrypoint"] as? String
            break
        }
        // Sessions that never did anything (no title, no PR) aren't worth offering.
        guard let cwd, title != nil || prNumber != nil else { return nil }

        let sessionId = file.deletingPathExtension().lastPathComponent
        return Agent(
            id: sessionId,
            kind: .local,
            source: claudeSource(for: entrypoint),
            name: title.map(oneLine) ?? sessionId,
            state: .idle,
            detail: nil,
            lastActivity: modified,
            prRepo: prRepo,
            prNumber: prNumber,
            // Not the branch: in a shared checkout it's whatever was checked out, not what the session worked on.
            branches: [],
            ticket: ticketID(in: (cwd as NSString).lastPathComponent) ?? title.flatMap(ticketID(in:)),
            openURL: nil,
            resumeCommand: "cd \(shellQuote(cwd)) && claude --resume \(sessionId)",
            running: false,
            cwd: cwd,
            worktree: worktreeName(containing: cwd)
        )
    }
}
