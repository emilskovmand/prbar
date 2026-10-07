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

    enum CI { case passing, failing, pending, none }

    var ci: CI {
        if checksFailed > 0 { return .failing }
        if checksPending > 0 { return .pending }
        if checksPassed > 0 { return .passing }
        return .none
    }

    var key: String { "\(repo)#\(number)" }
}

enum AgentState: Int, Comparable {
    case needsYou = 0, working, idle

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
}

/// Pulls a Linear-style ticket id ("bli-1637") out of a branch, path or title.
func ticketID(in text: String) -> String? {
    guard let r = text.range(of: #"(?i)\b[a-z]{2,6}-\d{2,6}\b"#, options: .regularExpression) else { return nil }
    return text[r].lowercased()
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
