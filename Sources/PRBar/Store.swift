import AppKit
import ServiceManagement

/// Polls every source, links agents to PRs, and publishes the result for the panel and menu bar title.
final class Store: ObservableObject {
    struct Row: Identifiable {
        let pr: PullRequest
        let agents: [Agent]
        /// The most recently active chat on this PR, running or ended, for the "open chat" button.
        let latestChat: Agent?
        var id: String { pr.key }
    }

    struct LinkedAgent: Identifiable {
        let agent: Agent
        let pr: PullRequest?
        var id: String { agent.id }
    }

    /// The counts shown in the menu bar, taken from exactly what the panel lists.
    struct Counts: Equatable {
        var needsYou = 0, ready = 0, drafts = 0, failing = 0
        /// Main agents working or watching, and every running subagent under any agent.
        var agentsRunning = 0, subagentsRunning = 0
    }

    @Published private(set) var ready: [Row] = []
    @Published private(set) var drafts: [Row] = []
    /// Your PRs merged in the last few days, newest first.
    @Published private(set) var merged: [Row] = []
    @Published private(set) var agents: [LinkedAgent] = []
    /// Other people's PRs waiting for your review, and ones you reviewed that got new commits since.
    @Published private(set) var reviewRequested: [ReviewPR] = []
    @Published private(set) var reviewUpdated: [ReviewPR] = []
    @Published private(set) var counts = Counts()
    @Published private(set) var githubError: String?
    @Published private(set) var cloudError: String?
    @Published private(set) var reviewError: String?
    @Published private(set) var githubUpdated: Date?
    /// A refresh from the panel's button is running; it shows a spinner.
    @Published private(set) var refreshing = false
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    /// Called on the main thread after every update, for the menu bar title.
    var onChange: (() -> Void)?

    private(set) var prs: [PullRequest] = []
    private(set) var mergedPRs: [PullRequest] = []
    private(set) var localAgents: [Agent] = []
    private(set) var cloudAgents: [Agent] = []
    private(set) var codexAgents: [Agent] = []
    private var history: [Agent] = []
    private var t3Chats: [T3Agents.Chat] = []

    private let local = LocalAgents()
    private let cloud = CloudAgents()
    private let codex = CodexAgents()
    private let t3 = T3Agents()
    private let sessionHistory = SessionHistory()
    private let localQueue = DispatchQueue(label: "prbar.local")
    private let githubQueue = DispatchQueue(label: "prbar.github")
    private let cloudQueue = DispatchQueue(label: "prbar.cloud")
    private let codexQueue = DispatchQueue(label: "prbar.codex")
    private let t3Queue = DispatchQueue(label: "prbar.t3")
    private let historyQueue = DispatchQueue(label: "prbar.history")
    private var githubInFlight = false
    /// Sources still polling; a slow poll is skipped rather than queued behind itself.
    private var polling = Set<String>()
    private var refreshStarted = Date.distantPast
    private var menuOpen = false
    private var publishPending = false
    private var timers: [Timer] = []

    func start() {
        // SwiftUI updates an open Menu's items whenever the panel redraws, and that closes an open
        // submenu (the gear menu's "Notify Me When"), so updates wait until the menu closes.
        let center = NotificationCenter.default
        // Only top-level menus count, so a submenu closing can't let updates through early.
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.object as? NSMenu)?.supermenu == nil else { return }
            self?.menuOpen = true
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? NSMenu)?.supermenu == nil else { return }
            self.menuOpen = false
            if self.publishPending { self.publish() }
        }
        // Agents change by the second; PRs don't, and GitHub's API is rate limited.
        schedule(every: 1) { [weak self] in self?.refreshLocal() }
        schedule(every: 45) { [weak self] in self?.refreshGitHub() }
        schedule(every: 15) { [weak self] in self?.refreshCloud() }
        schedule(every: 2) { [weak self] in self?.refreshCodex() }
        schedule(every: 2) { [weak self] in self?.refreshT3() }
        schedule(every: 60) { [weak self] in self?.refreshHistory() }
    }

    func refreshAll() {
        refreshing = true
        refreshStarted = Date()
        refreshLocal(); refreshGitHub(); refreshCloud(); refreshCodex(); refreshT3()
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("PRBar: login item toggle failed: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func schedule(every interval: TimeInterval, _ block: @escaping () -> Void) {
        block()
        let t = Timer(timeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    // MARK: Refresh

    private func refreshLocal() {
        guard polling.insert("local").inserted else { return }
        localQueue.async { [weak self] in
            guard let self else { return }
            let agents = self.local.poll()
            DispatchQueue.main.async {
                self.polling.remove("local")
                // An agent finishing a turn has often just pushed, so pull fresh PR state right away.
                let finished = self.localAgents.contains { old in
                    old.state == .working && agents.first { $0.id == old.id }?.state != .working
                }
                self.localAgents = agents
                if finished { self.refreshGitHub() }
                self.publish()
            }
        }
    }

    private func refreshGitHub() {
        guard !githubInFlight else { return }
        githubInFlight = true
        githubQueue.async { [weak self] in
            let result = Result { try GitHub.fetchMyPRs() }
            let review = Result { try GitHub.fetchReviewQueue() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.githubInFlight = false
                switch result {
                case .success(let mine):
                    self.prs = mine.open; self.mergedPRs = mine.merged
                    self.githubError = nil; self.githubUpdated = Date()
                case .failure(let e): self.githubError = "\(e)"
                }
                self.setReview(review)
                self.publish()
                self.endRefreshing()
            }
        }
    }

    /// GitHub is the slowest source, so the spinner stops when it's back, but stays up long enough
    /// to register as a response to the click.
    private func endRefreshing() {
        guard refreshing else { return }
        let wait = max(0, 0.6 + refreshStarted.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.refreshing = false }
    }

    private func setReview(_ result: Result<(requested: [ReviewPR], updated: [ReviewPR]), Error>) {
        switch result {
        case .success(let queue):
            reviewRequested = queue.requested
            reviewUpdated = queue.updated
            reviewError = nil
        case .failure(let e): reviewError = "\(e)"
        }
    }

    private func refreshCloud() {
        guard polling.insert("cloud").inserted else { return }
        cloudQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.cloud.poll() }
            DispatchQueue.main.async {
                self.polling.remove("cloud")
                switch result {
                case .success(let agents): self.cloudAgents = agents; self.cloudError = nil
                case .failure(let e): self.cloudError = "\(e)"
                }
                self.publish()
            }
        }
    }

    private func refreshCodex() {
        guard polling.insert("codex").inserted else { return }
        codexQueue.async { [weak self] in
            guard let self else { return }
            let agents = self.codex.poll()
            DispatchQueue.main.async {
                self.polling.remove("codex")
                self.codexAgents = agents
                self.publish()
            }
        }
    }

    private func refreshT3() {
        guard polling.insert("t3").inserted else { return }
        t3Queue.async { [weak self] in
            guard let self else { return }
            let chats = self.t3.poll()
            DispatchQueue.main.async {
                self.polling.remove("t3")
                let workingIDs = Set(chats.filter { $0.agent.state == .working }.map { $0.agent.id })
                let finished = self.t3Chats.contains { $0.agent.state == .working && !workingIDs.contains($0.agent.id) }
                self.t3Chats = chats
                if finished { self.refreshGitHub() }
                self.publish()
            }
        }
    }

    private func refreshHistory() {
        historyQueue.async { [weak self] in
            guard let self else { return }
            let past = self.sessionHistory.poll() + self.codex.history()
            DispatchQueue.main.async {
                self.history = past
                self.publish()
            }
        }
    }

    private func publish() {
        guard !menuOpen else { publishPending = true; return }
        publishPending = false
        let rows = link()
        ready = rows.open.filter { !$0.pr.isDraft }
        drafts = rows.open.filter { $0.pr.isDraft }
        merged = rows.merged
        agents = sortAgents(visibleAgents()).map { LinkedAgent(agent: $0, pr: match($0)) }
        counts = Counts(
            needsYou: agents.filter { $0.agent.state == .needsYou }.count,
            ready: ready.count,
            drafts: drafts.count,
            // Red in the panel: a red ✗ for failing CI or red "conflicts" text.
            failing: prs.filter { $0.ci == .failing || $0.mergeable == "CONFLICTING" }.count,
            agentsRunning: agents.filter { $0.agent.state == .working || $0.agent.state == .watching }.count,
            subagentsRunning: agents.reduce(0) { $0 + $1.agent.runningSubagents }
        )
        onChange?()
    }

    /// Active local chats, plus cloud sessions on an open PR or active in the last few days.
    private func visibleAgents() -> [Agent] {
        let listedT3 = t3Chats.filter(\.listed)
        let nativeIDs = Set(listedT3.flatMap(\.nativeSessionIDs))
        let standalone = (localAgents + codexAgents).filter { !nativeIDs.contains($0.id) }
        return standalone + listedT3.map(\.agent) + cloudAgents.filter { match($0) != nil || isRecent($0) }
    }

    // MARK: Linking

    func link() -> (open: [Row], merged: [Row]) {
        // An agent belongs to its open PR first; merged PRs only get the ones no open PR claims.
        let linkable = { (agent: Agent) in self.match(agent) ?? self.match(agent, in: self.mergedPRs) }
        let live = visibleAgents()
        var byPR: [String: [Agent]] = [:]
        for agent in live {
            if let pr = linkable(agent) { byPR[pr.key, default: []].append(agent) }
        }
        // T3 owns opening its own chats, even if the provider also exposes their transcripts.
        let liveIDs = Set(live.map(\.id))
        var pastByPR: [String: [Agent]] = [:]
        var t3NativeIDsByPR: [String: Set<String>] = [:]
        for chat in t3Chats {
            guard let pr = linkable(chat.agent) else { continue }
            t3NativeIDsByPR[pr.key, default: []].formUnion(chat.nativeSessionIDs)
            if !liveIDs.contains(chat.agent.id) { pastByPR[pr.key, default: []].append(chat.agent) }
        }
        for agent in history where !liveIDs.contains(agent.id) {
            if let pr = linkable(agent) { pastByPR[pr.key, default: []].append(agent) }
        }

        func row(_ pr: PullRequest) -> Row {
            let agents = byPR[pr.key] ?? []
            let latest = (agents + (pastByPR[pr.key] ?? [])).filter {
                t3NativeIDsByPR[pr.key]?.contains($0.id) != true
            }.max {
                ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast)
            }
            return Row(pr: pr, agents: sortAgents(agents), latestChat: latest)
        }

        let open = prs.map(row)
            .enumerated()
            .sorted { a, b in
                let (pa, pb) = (priority(a.element), priority(b.element))
                return pa != pb ? pa < pb : a.offset < b.offset
            }
            .map(\.element)
        return (open, mergedPRs.map(row))
    }

    func match(_ agent: Agent) -> PullRequest? { match(agent, in: prs) }

    private func match(_ agent: Agent, in prs: [PullRequest]) -> PullRequest? {
        if let n = agent.prNumber,
           let pr = prs.first(where: { $0.number == n && (agent.prRepo == nil || $0.repo == agent.prRepo) }) {
            return pr
        }
        if let pr = prs.first(where: { agent.branches.contains($0.headRef) }) { return pr }
        if let t = agent.ticket, let pr = prs.first(where: { ticket(of: $0.headRef) == t }) { return pr }
        return nil
    }

    /// Branch → ticket id, since linking runs on every poll for every agent and every PR.
    private var branchTickets: [String: String?] = [:]

    private func ticket(of branch: String) -> String? {
        if let t = branchTickets[branch] { return t }
        if branchTickets.count > 2000 { branchTickets = [:] }
        let t = ticketID(in: branch)
        branchTickets[branch] = t
        return t
    }

    private func isRecent(_ agent: Agent) -> Bool {
        agent.state == .working || agent.state == .watching || (agent.lastActivity.map { -$0.timeIntervalSinceNow < 3 * 86400 } ?? false)
    }

    private func sortAgents(_ agents: [Agent]) -> [Agent] {
        agents.sorted {
            $0.state != $1.state ? $0.state < $1.state : ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    /// Lower sorts first: things waiting on you, then broken, then review feedback, then in progress.
    private func priority(_ row: Row) -> Int {
        if row.agents.contains(where: { $0.state == .needsYou }) { return 0 }
        if row.pr.ci == .failing || row.pr.mergeable == "CONFLICTING" { return 1 }
        if row.pr.reviewDecision == "CHANGES_REQUESTED" || row.pr.unresolvedThreads > 0 { return 2 }
        if row.agents.contains(where: { $0.state == .working || $0.state == .watching }) { return 3 }
        return 4
    }

    // MARK: Debugging

    /// Polls every source once, synchronously, and publishes the result.
    func loadOnce() {
        localAgents = local.poll()
        codexAgents = codex.poll()
        t3Chats = t3.poll()
        history = sessionHistory.poll() + codex.history()
        do {
            (prs, mergedPRs) = try GitHub.fetchMyPRs()
            githubUpdated = Date()
        } catch { githubError = "\(error)" }
        setReview(Result { try GitHub.fetchReviewQueue() })
        do { cloudAgents = try cloud.poll() } catch { cloudError = "\(error)" }
        publish()
    }

    /// Fills the panel with the made-up data in `Demo`, for the README screenshots.
    func loadDemo() {
        prs = Demo.prs
        mergedPRs = Demo.merged
        localAgents = Demo.localAgents
        cloudAgents = Demo.cloudAgents
        codexAgents = Demo.codexAgents
        t3Chats = []
        history = []
        reviewRequested = Demo.reviewRequested
        reviewUpdated = Demo.reviewUpdated
        githubUpdated = Date(timeIntervalSinceNow: -12)
        publish()
    }

    /// `PRBar --dump`: poll every source once and print what the panel would show.
    func dump() {
        loadOnce()
        print("counts: \(counts)")
        for row in ready + drafts {
            let pr = row.pr
            print("#\(pr.number) ci=\(pr.ci) review=\(pr.reviewDecision ?? "-") threads=\(pr.unresolvedThreads) \(pr.mergeable) draft=\(pr.isDraft) agents=\(row.agents.map { "\($0.state)" }) latest=\(row.latestChat.map { "[\($0.source)\($0.running ? " running" : "")] \($0.name) \(relativeTime($0.lastActivity))" } ?? "-")")
        }
        for row in merged {
            print("#\(row.pr.number) merged \(relativeTime(row.pr.mergedAt)) ago latest=\(row.latestChat.map { "[\($0.source)] \($0.name)" } ?? "-")")
        }
        print("-- review: \(reviewError ?? "ok")")
        for r in reviewRequested + reviewUpdated {
            print("  \(r.pr.repo)#\(r.pr.number) by \(r.pr.author) requested=\(relativeTime(r.requestedAt)) mine=\(r.myReview ?? "-") newCommits=\(r.hasNewCommits) \(r.pr.title)")
        }
        print("-- agents")
        for a in agents {
            print("  \(a.agent.state) [\(a.agent.source)] \(a.agent.name) \(a.pr.map { "#\($0.number)" } ?? "-") \(relativeTime(a.agent.lastActivity)) worktree=\(a.agent.worktree ?? "-")\(a.agent.hasCodeChanges ? " code-changes" : "")")
            if a.agent.finishedSubagents > 0 { print("      \(a.agent.finishedSubagents) subagents finished") }
            for s in a.agent.subagents {
                print("      \(s.watching ? "watching" : s.running ? "running" : "done") \(s.id) parent=\(s.parentID ?? "main") [\(s.type ?? "general")] \(s.name) \(relativeTime(s.lastActivity))")
            }
        }
    }
}
