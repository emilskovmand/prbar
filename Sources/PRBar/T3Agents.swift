import Foundation
import SQLite3

final class T3Agents {
    struct Chat {
        let agent: Agent
        let listed: Bool
        let nativeSessionIDs: Set<String>
    }

    private let stateDirectory: URL

    init(stateDirectory: URL? = nil) {
        let home =
            ProcessInfo.processInfo.environment["T3CODE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.t3"
        self.stateDirectory = stateDirectory ?? URL(fileURLWithPath: home).appendingPathComponent("userdata")
    }

    func poll() -> [Chat] {
        let environmentFile = stateDirectory.appendingPathComponent("environment-id")
        guard
            let environmentID = try? String(contentsOf: environmentFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !environmentID.isEmpty
        else { return [] }

        var db: OpaquePointer?
        let path = stateDirectory.appendingPathComponent("statev2.sqlite").path
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        sqlite3_busy_timeout(db, 250)

        let sql = """
            SELECT thread.thread_id, thread.title, thread.updated_at, project.workspace_root,
                   json_extract(thread.payload_json, '$.worktreePath'),
                   json_extract(thread.payload_json, '$.branch'),
                   (json_extract(thread.payload_json, '$.settledAt') IS NULL
                    AND json_extract(thread.payload_json, '$.settledOverride') IS NOT 'settled'),
                   json_extract(thread.payload_json, '$.linkedPullRequest'),
                   json_extract(thread.payload_json, '$.pullRequests'),
                   json_extract(thread.payload_json, '$.branchPullRequest'),
                   EXISTS (SELECT 1 FROM orchestration_v2_projection_runtime_requests request
                           WHERE request.thread_id = thread.thread_id AND request.status = 'pending'),
                   (SELECT run.status FROM orchestration_v2_projection_runs run
                    WHERE run.thread_id = thread.thread_id
                      AND run.status IN ('preparing', 'queued', 'starting', 'running', 'waiting')
                    ORDER BY run.status = 'queued', run.ordinal DESC LIMIT 1),
                   (SELECT json_group_array(DISTINCT json_extract(provider.payload_json, '$.nativeThreadRef.nativeId'))
                    FROM orchestration_v2_projection_provider_threads provider
                    WHERE provider.thread_id = thread.thread_id AND provider.owner_node_id IS NULL
                      AND provider.provider IN ('claudeAgent', 'codex')
                      AND json_extract(provider.payload_json, '$.nativeThreadRef.strength') = 'strong')
            FROM orchestration_v2_projection_threads thread
            JOIN projection_projects project ON project.project_id = thread.project_id
            WHERE thread.deleted_at IS NULL AND thread.archived_at IS NULL
              AND project.deleted_at IS NULL AND project.archived_at IS NULL
              AND json_extract(thread.payload_json, '$.lineage.relationshipToParent') IS NOT 'subagent'
              AND json_extract(thread.payload_json, '$.lineage.sideChat') IS NOT 1
              AND ((json_extract(thread.payload_json, '$.settledAt') IS NULL
                    AND json_extract(thread.payload_json, '$.settledOverride') IS NOT 'settled')
                   OR unixepoch(thread.updated_at) >= ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970))

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }

        var chats: [Chat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(0), let title = text(1), let root = text(3),
                let url = Self.threadURL(environmentID: environmentID, threadID: id)
            else { continue }

            let worktree = text(4)
            let branch = text(5)
            let cwd = worktree ?? root
            let links = decode([PRLink].self, text(8)) ?? []
            let pr =
                decode(PRLink.self, text(7)).flatMap { $0.isGitHub ? $0 : nil }
                ?? links.first { $0.isGitHub && $0.source != "stack-dismissed" }
                ?? decode(PRLink.self, text(9)).flatMap { $0.isGitHub ? $0 : nil }
            let nativeIDs = Set((decode([String?].self, text(12)) ?? []).compactMap { $0 })
            let runStatus = text(11)
            let state: AgentState =
                if sqlite3_column_int(statement, 10) != 0 {
                    .needsYou
                } else if runStatus == "waiting" {
                    .watching
                } else if runStatus != nil {
                    .working
                } else {
                    .idle
                }

            let agent = Agent(
                id: "t3:\(id)", kind: .t3, source: "T3 Code", name: title, state: state, detail: nil,
                lastActivity: text(2).flatMap(parseISO), prRepo: pr?.repository, prNumber: pr?.number,
                branches: branch.map { [$0] } ?? [],
                ticket: ticketID(in: (cwd as NSString).lastPathComponent) ?? branch.flatMap(ticketID(in:))
                    ?? ticketID(in: title),
                openURL: url, resumeCommand: nil, running: state != .idle, cwd: cwd,
                worktree: worktree.map { ($0 as NSString).lastPathComponent }
            )
            chats.append(Chat(agent: agent, listed: sqlite3_column_int(statement, 6) != 0, nativeSessionIDs: nativeIDs))
        }
        return chats
    }

    private struct PRLink: Decodable {
        let repository: String
        let number: Int
        let url: URL
        let source: String?

        var isGitHub: Bool { url.host?.lowercased() == "github.com" }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String?) -> Value? {
        json.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }

    private static func threadURL(environmentID: String, threadID: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let environment = environmentID.addingPercentEncoding(withAllowedCharacters: allowed),
            let thread = threadID.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "t3code://threads/\(environment)/\(thread)")
    }
}
