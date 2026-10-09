import Foundation

struct PullRequest {
    let repo: String
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let headRef: String
    let reviewDecision: String?   // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
    let mergeable: String         // MERGEABLE, CONFLICTING, UNKNOWN
    let unresolvedThreads: Int
    let checksPassed: Int
    let checksFailed: Int
    let checksPending: Int
    var author = ""
    var createdAt: Date? = nil
    var lastCommitAt: Date? = nil

    enum CI { case passing, failing, pending, none }

    var ci: CI {
        if checksFailed > 0 { return .failing }
        if checksPending > 0 { return .pending }
        if checksPassed > 0 { return .passing }
        return .none
    }

    var key: String { "\(repo)#\(number)" }
}

/// Someone else's PR in your review queue.
struct ReviewPR: Identifiable {
    let pr: PullRequest
    /// When your review was last requested.
    let requestedAt: Date?
    /// Your latest review: APPROVED, CHANGES_REQUESTED, COMMENTED…
    let myReview: String?
    let myReviewAt: Date?

    var id: String { pr.key }

    var hasNewCommits: Bool {
        guard let commit = pr.lastCommitAt, let review = myReviewAt else { return false }
        return commit > review
    }
}

enum AgentState: Int, Comparable {
    case needsYou = 0, working, watching, idle

    static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }
}

struct Agent {
    enum Kind { case local, cloud, codex }

    let id: String
    let kind: Kind
    let source: String         // shown in the panel: CLI, Desktop, VS Code, Codex, Cloud
    let name: String
    let state: AgentState
    let detail: String?        // last prompt / turn summary
    let lastActivity: Date?
    // Linking hints, strongest first.
    let prRepo: String?
    let prNumber: Int?
    let branches: [String]
    let ticket: String?        // e.g. "bli-1637"
    let openURL: URL?
    let resumeCommand: String?
    // Used to open the chat: a running local session is focused in its terminal tab,
    // an ended one is resumed in a new terminal window.
    var running = true
    var cwd: String? = nil
    var worktree: String? = nil     // the git worktree folder the agent works in, e.g. "bli-1599"
    var tty: String? = nil          // e.g. /dev/ttys002
    var hostApp: URL? = nil         // the app the session runs in (iTerm, Terminal, Cursor, Claude…)
}

/// Pulls a Linear-style ticket id ("bli-1637") out of a branch, path or title.
func ticketID(in text: String) -> String? {
    guard let r = text.range(of: #"(?i)\b[a-z]{2,6}-\d{2,6}\b"#, options: .regularExpression) else { return nil }
    return text[r].lowercased()
}

/// The folder name of the linked git worktree that `path` is in ("…/.claude/worktrees/bli-1599" → "bli-1599"),
/// or nil in a main checkout or outside git. A worktree's `.git` is a file pointing into the main
/// checkout's `.git/worktrees/`; a submodule's `.git` file points into `.git/modules/` instead.
func worktreeName(containing path: String) -> String? {
    var dir = URL(fileURLWithPath: path).standardizedFileURL
    while dir.path != "/" {
        let git = dir.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
            guard !isDir.boolValue, let link = try? String(contentsOf: git, encoding: .utf8),
                  link.contains("/worktrees/") else { return nil }
            return dir.lastPathComponent
        }
        dir.deleteLastPathComponent()
    }
    return nil
}

func relativeTime(_ date: Date?) -> String {
    guard let date else { return "" }
    let s = Int(-date.timeIntervalSinceNow)
    switch s {
    case ..<60: return "\(max(s, 0))s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h"
    default: return "\(s / 86400)d"
    }
}

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    if let d = isoFormatter.date(from: s) { return d }
    // The cloud API uses microsecond precision, which ISO8601DateFormatter rejects.
    let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
    return isoFormatter.date(from: trimmed)
}
