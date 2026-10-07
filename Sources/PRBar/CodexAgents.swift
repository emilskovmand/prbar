import Foundation
import SQLite3

/// Reads Codex (CLI and desktop app) threads from ~/.codex/state_*.sqlite and works out each
/// thread's state from the task events at the end of its rollout log.
final class CodexAgents {
    private let codexDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")

    /// Without a running Codex process, only threads with an unfinished task are shown.
    private let recentWindow: TimeInterval = 12 * 3600
    /// A task with no new events for this long is treated as abandoned rather than working.
    private let staleTask: TimeInterval = 15 * 60

    private struct Thread {
        let id, rolloutPath, cwd, title: String
        let branch: String?
        let updated: Date
    }

    func poll() -> [Agent] {
        guard let db = openDatabase() else { return [] }
        defer { sqlite3_close(db) }

        let running = isCodexRunning()
        let since = Date().addingTimeInterval(-(running ? recentWindow : staleTask))
        return threads(db, updatedSince: since).compactMap { t in
            let (state, detail) = taskState(t)
            if !running && state == .idle { return nil }
            return Agent(
                id: t.id,
                kind: .codex,
                source: "Codex",
                name: t.title,
                state: state,
                detail: detail,
                lastActivity: t.updated,
                prRepo: nil,
                prNumber: nil,
                branches: t.branch.map { [$0] } ?? [],
                ticket: ticketID(in: (t.cwd as NSString).lastPathComponent) ?? t.branch.flatMap(ticketID(in:)),
                openURL: nil,
                resumeCommand: "cd \(shellQuote(t.cwd)) && codex resume \(t.id)"
            )
        }
    }

    // MARK: State database

    private func openDatabase() -> OpaquePointer? {
        // The schema version is in the file name (state_5.sqlite); use the newest.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: codexDir.path)) ?? []
        let newest = files
            .filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .max { (Int($0.dropFirst(6).dropLast(7)) ?? 0) < (Int($1.dropFirst(6).dropLast(7)) ?? 0) }
        guard let newest else { return nil }

        var db: OpaquePointer?
        let path = codexDir.appendingPathComponent(newest).path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 500)
        return db
    }

    private func threads(_ db: OpaquePointer, updatedSince since: Date) -> [Thread] {
        let sql = """
            SELECT id, rollout_path, cwd, COALESCE(NULLIF(name, ''), title), git_branch, updated_at_ms
            FROM threads
            WHERE archived = 0 AND updated_at_ms >= ?
              -- Codex mirrors Claude Code sessions in here with no originator; those are already listed.
              AND COALESCE(originator, '') != ''
              -- Internal sub-agents (e.g. guardian reviews) belong to their parent thread.
              AND source NOT LIKE '{%'
            ORDER BY updated_at_ms DESC
            LIMIT 25
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))

        func text(_ i: Int32) -> String? {
            sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
        var result: [Thread] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(0), let rollout = text(1) else { continue }
            result.append(Thread(
                id: id,
                rolloutPath: rollout,
                cwd: text(2) ?? "",
                title: oneLine(text(3) ?? id),
                branch: text(4).flatMap { $0.isEmpty ? nil : $0 },
                updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5)) / 1000)
            ))
        }
        return result
    }

    // MARK: Rollout log

    /// Working if the last task started hasn't completed, needs you if it stopped on an approval request.
    private func taskState(_ t: Thread) -> (AgentState, String?) {
        let url = URL(fileURLWithPath: t.rolloutPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (.idle, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 256_000 ? size - 256_000 : 0)
        let tail = (try? handle.readToEnd()) ?? Data()

        var inTask = false
        var awaitingApproval = false
        var lastPrompt: String?
        for line in tail.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            switch type {
            case "task_started": inTask = true; awaitingApproval = false
            case "task_complete", "turn_aborted": inTask = false; awaitingApproval = false
            case "user_message": lastPrompt = (payload["message"] as? String).map { "› " + oneLine($0) }
            case let x where x.hasSuffix("approval_request"): awaitingApproval = true
            default: if inTask { awaitingApproval = false }
            }
        }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? t.updated
        if inTask && -modified.timeIntervalSinceNow < staleTask {
            return (awaitingApproval ? .needsYou : .working, lastPrompt)
        }
        return (.idle, lastPrompt)
    }

    private func isCodexRunning() -> Bool {
        (try? Shell.run(["pgrep", "-i", "codex"], timeout: 5)) != nil
    }
}
