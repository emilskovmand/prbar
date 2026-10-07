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
    }

    @Published private(set) var ready: [Row] = []
    @Published private(set) var drafts: [Row] = []
    @Published private(set) var agents: [LinkedAgent] = []
    /// Other people's PRs waiting for your review, and ones you reviewed that got new commits since.
    @Published private(set) var reviewRequested: [ReviewPR] = []
    @Published private(set) var reviewUpdated: [ReviewPR] = []
    @Published private(set) var counts = Counts()
    @Published private(set) var githubError: String?
    @Published private(set) var cloudError: String?
    @Published private(set) var reviewError: String?
    @Published private(set) var githubUpdated: Date?
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled

    /// Called on the main thread after every update, for the menu bar title.
    var onChange: (() -> Void)?

    private(set) var prs: [PullRequest] = []
    private(set) var localAgents: [Agent] = []
    private(set) var cloudAgents: [Agent] = []
    private(set) var codexAgents: [Agent] = []
    private var history: [Agent] = []

    private let local = LocalAgents()
    private let cloud = CloudAgents()
    private let codex = CodexAgents()
    private let sessionHistory = SessionHistory()
    private let localQueue = DispatchQueue(label: "prbar.local")
    private let githubQueue = DispatchQueue(label: "prbar.github")
    private let cloudQueue = DispatchQueue(label: "prbar.cloud")
    private let codexQueue = DispatchQueue(label: "prbar.codex")
    private let historyQueue = DispatchQueue(label: "prbar.history")
    private var githubInFlight = false
    private var timers: [Timer] = []

    func start() {
        schedule(every: 3) { [weak self] in self?.refreshLocal() }
        schedule(every: 45) { [weak self] in self?.refreshGitHub() }
        schedule(every: 30) { [weak self] in self?.refreshCloud() }
        schedule(every: 5) { [weak self] in self?.refreshCodex() }
        schedule(every: 60) { [weak self] in self?.refreshHistory() }
    }

    func refreshAll() {
        refreshLocal(); refreshGitHub(); refreshCloud(); refreshCodex()
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
        localQueue.async { [weak self] in
            guard let self else { return }
            let agents = self.local.poll()
            DispatchQueue.main.async {
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
            let result = Result { try GitHub.fetchOpenPRs() }
            let review = Result { try GitHub.fetchReviewQueue() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.githubInFlight = false
                switch result {
                case .success(let prs): self.prs = prs; self.githubError = nil; self.githubUpdated = Date()
                case .failure(let e): self.githubError = "\(e)"
                }
                self.setReview(review)
                self.publish()
            }
        }
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
        cloudQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.cloud.poll() }
            DispatchQueue.main.async {
                switch result {
                case .success(let agents): self.cloudAgents = agents; self.cloudError = nil
                case .failure(let e): self.cloudError = "\(e)"
                }
                self.publish()
            }
        }
    }

    private func refreshCodex() {
        codexQueue.async { [weak self] in
            guard let self else { return }
            let agents = self.codex.poll()
            DispatchQueue.main.async {
                self.codexAgents = agents
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
        let rows = link()
        ready = rows.filter { !$0.pr.isDraft }
        drafts = rows.filter { $0.pr.isDraft }
        agents = sortAgents(visibleAgents()).map { LinkedAgent(agent: $0, pr: match($0)) }
        counts = Counts(
            needsYou: agents.filter { $0.agent.state == .needsYou }.count,
            ready: ready.count,
            drafts: drafts.count,
            // Red in the panel: a red ✗ for failing CI or red "conflicts" text.
            failing: prs.filter { $0.ci == .failing || $0.mergeable == "CONFLICTING" }.count
        )
        onChange?()
    }

    /// Every local agent (CLI, Desktop, IDE) and Codex thread that's running, plus cloud sessions
    /// that are on an open PR or active in the last few days.
    private func visibleAgents() -> [Agent] {
        localAgents + codexAgents + cloudAgents.filter { match($0) != nil || isRecent($0) }
    }

    // MARK: Linking

    func link() -> [Row] {
        let live = visibleAgents()
        var byPR: [String: [Agent]] = [:]
        for agent in live {
            if let pr = match(agent) { byPR[pr.key, default: []].append(agent) }
        }
        // Past chats, skipping any that are running (the live entry knows its terminal tab).
        let liveIDs = Set(live.map(\.id))
        var pastByPR: [String: [Agent]] = [:]
        for agent in history where !liveIDs.contains(agent.id) {
            if let pr = match(agent) { pastByPR[pr.key, default: []].append(agent) }
        }

        let rows = prs.map { pr in
            let agents = byPR[pr.key] ?? []
            let latest = (agents + (pastByPR[pr.key] ?? [])).max {
                ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast)
            }
            return Row(pr: pr, agents: sortAgents(agents), latestChat: latest)
        }
            .enumerated()
            .sorted { a, b in
                let (pa, pb) = (priority(a.element), priority(b.element))
                return pa != pb ? pa < pb : a.offset < b.offset
            }
            .map(\.element)
        return rows
    }

    func match(_ agent: Agent) -> PullRequest? {
        if let n = agent.prNumber,
           let pr = prs.first(where: { $0.number == n && (agent.prRepo == nil || $0.repo == agent.prRepo) }) {
            return pr
        }
        if let pr = prs.first(where: { agent.branches.contains($0.headRef) }) { return pr }
        if let t = agent.ticket, let pr = prs.first(where: { ticketID(in: $0.headRef) == t }) { return pr }
        return nil
    }

    private func isRecent(_ agent: Agent) -> Bool {
        agent.state == .working || (agent.lastActivity.map { -$0.timeIntervalSinceNow < 3 * 86400 } ?? false)
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
        if row.agents.contains(where: { $0.state == .working }) { return 3 }
        return 4
    }

    // MARK: Debugging

    /// Polls every source once, synchronously, and publishes the result.
    func loadOnce() {
        localAgents = local.poll()
        codexAgents = codex.poll()
        history = sessionHistory.poll() + codex.history()
        do { prs = try GitHub.fetchOpenPRs(); githubUpdated = Date() } catch { githubError = "\(error)" }
        setReview(Result { try GitHub.fetchReviewQueue() })
        do { cloudAgents = try cloud.poll() } catch { cloudError = "\(error)" }
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
        print("-- review: \(reviewError ?? "ok")")
        for r in reviewRequested + reviewUpdated {
            print("  \(r.pr.repo)#\(r.pr.number) by \(r.pr.author) requested=\(relativeTime(r.requestedAt)) mine=\(r.myReview ?? "-") newCommits=\(r.hasNewCommits) \(r.pr.title)")
        }
        print("-- agents")
        for a in agents {
            print("  \(a.agent.state) [\(a.agent.source)] \(a.agent.name) \(a.pr.map { "#\($0.number)" } ?? "-") \(relativeTime(a.agent.lastActivity))")
        }
    }
}
