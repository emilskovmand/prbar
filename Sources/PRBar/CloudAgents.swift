import Foundation

/// Lists Claude Code cloud sessions using the OAuth token the `claude` CLI keeps in the keychain.
/// The token is only read locally and sent to api.anthropic.com; it is never refreshed here,
/// so the CLI stays the owner of the login.
final class CloudAgents {
    enum Failure: Error, CustomStringConvertible {
        case noLogin, expired, http(Int)
        var description: String {
            switch self {
            case .noLogin: return "no Claude login in keychain"
            case .expired: return "login expired — run `claude` once to refresh"
            case .http(let code): return "HTTP \(code)"
            }
        }
    }

    private var token: String?

    func poll() throws -> [Agent] {
        do {
            return try fetch()
        } catch Failure.expired {
            token = nil  // the CLI may have refreshed it since we last read it
            return try fetch()
        }
    }

    private func fetch() throws -> [Agent] {
        if token == nil { token = try readToken() }
        guard let token else { throw Failure.noLogin }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/code/sessions?limit=50")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("ccr-byoc-2025-07-29", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 20

        let (data, status) = try syncRequest(req)
        if status == 401 || status == 403 { throw Failure.expired }
        guard status == 200 else { throw Failure.http(status) }

        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sessions = root?["data"] as? [[String: Any]] ?? []
        return sessions.compactMap(agent(from:))
    }

    private func agent(from s: [String: Any]) -> Agent? {
        guard let id = s["id"] as? String, s["status"] as? String == "active" else { return nil }

        let meta = s["external_metadata"] as? [String: Any] ?? [:]
        let summary = meta["post_turn_summary"] as? [String: Any] ?? [:]
        let config = s["config"] as? [String: Any] ?? [:]

        var branches: [String] = []
        var repo: String?
        for outcome in config["outcomes"] as? [[String: Any]] ?? [] {
            guard let git = outcome["git_info"] as? [String: Any] else { continue }
            branches += git["branches"] as? [String] ?? []
            repo = repo ?? git["repo"] as? String
        }
        if let current = meta["current_branches"] as? [String: Any] {
            branches += current.values.compactMap { $0 as? String }
        }

        let texts = ["status_detail", "recent_action", "needs_action"].compactMap { summary[$0] as? String }
        let prNumber = texts.lazy.compactMap(Self.prNumber(in:)).first

        let worker = s["worker_status"] as? String ?? ""
        let state: AgentState
        if ["running", "busy", "working", "active"].contains(worker) {
            state = .working
        } else if summary["status_category"] as? String == "need_input" || s["status_bucket"] as? String == "blocked" {
            state = .needsYou
        } else {
            state = .idle
        }

        let title = s["title"] as? String ?? id
        let detail = (summary["needs_action"] as? String) ?? (summary["status_detail"] as? String)
        return Agent(
            id: id,
            kind: .cloud,
            source: "Cloud",
            name: title,
            state: state,
            detail: detail.map(oneLine),
            lastActivity: parseISO(s["last_event_at"] as? String) ?? parseISO(s["updated_at"] as? String),
            prRepo: prNumber == nil ? nil : repo,
            prNumber: prNumber,
            branches: branches,
            ticket: branches.lazy.compactMap(ticketID(in:)).first ?? ticketID(in: title),
            openURL: URL(string: "https://claude.ai/code/\(id)"),
            resumeCommand: nil
        )
    }

    private static func prNumber(in text: String) -> Int? {
        guard let r = text.range(of: #"PR #(\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[r].dropFirst(4))
    }

    private func readToken() throws -> String? {
        let data = try Shell.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 10)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    }

    private func syncRequest(_ req: URLRequest) throws -> (Data, Int) {
        var result: Result<(Data, Int), Error> = .failure(Failure.http(0))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) }
            else { result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)) }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}
