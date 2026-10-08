import Foundation

/// Made-up PRs, agents and review requests for `PRBar --demo-screenshots`, which renders the README images.
enum Demo {
    private static let repo = "acme/shop"

    private static func pr(_ number: Int, _ title: String, draft: Bool = false, review: String? = nil,
                           mergeable: String = "MERGEABLE", threads: Int = 0, passed: Int = 6, failed: Int = 0,
                           pending: Int = 0, author: String = "you", age: TimeInterval = 86400,
                           newCommits: Bool = false) -> PullRequest {
        PullRequest(
            repo: repo, number: number, title: title,
            url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
            isDraft: draft, headRef: "branch-\(number)", reviewDecision: review, mergeable: mergeable,
            unresolvedThreads: threads, checksPassed: passed, checksFailed: failed, checksPending: pending,
            author: author, createdAt: Date(timeIntervalSinceNow: -age),
            lastCommitAt: Date(timeIntervalSinceNow: newCommits ? -600 : -age)
        )
    }

    static let prs = [
        pr(412, "Add Apple Pay to checkout", review: "CHANGES_REQUESTED"),
        pr(418, "Fix flaky inventory sync job", mergeable: "CONFLICTING", failed: 1),
        pr(405, "Cache product images at the edge", review: "APPROVED"),
        pr(421, "Upgrade to React 19", pending: 4),
        pr(423, "Gift cards: balance lookup", draft: true),
        pr(399, "Spike: semantic product search", draft: true, mergeable: "CONFLICTING", passed: 3, failed: 2),
    ]

    private static func agent(_ kind: Agent.Kind, _ source: String, _ name: String, _ state: AgentState,
                              ago: TimeInterval, pr: Int?, worktree: String? = nil) -> Agent {
        Agent(id: name, kind: kind, source: source, name: name, state: state, detail: nil,
              lastActivity: Date(timeIntervalSinceNow: -ago), prRepo: pr == nil ? nil : repo, prNumber: pr,
              branches: [], ticket: nil, openURL: nil, resumeCommand: nil, worktree: worktree)
    }

    static let localAgents = [
        agent(.local, "CLI", "Fix flaky inventory sync", .working, ago: 12, pr: 418, worktree: "inventory-sync"),
        agent(.local, "Desktop", "Gift card balance API", .working, ago: 70, pr: 423, worktree: "gift-cards"),
        agent(.local, "CLI", "Explain the order state machine", .idle, ago: 5 * 3600, pr: nil),
    ]
    static let cloudAgents = [agent(.cloud, "Cloud", "Apple Pay checkout", .needsYou, ago: 180, pr: 412)]
    static let codexAgents = [agent(.codex, "Codex", "Edge caching for product images", .idle, ago: 2 * 3600, pr: 405)]

    static let reviewRequested = [
        ReviewPR(pr: pr(431, "Rate-limit the public API", author: "jane-doe", age: 5 * 3600),
                 requestedAt: Date(timeIntervalSinceNow: -3 * 3600), myReview: nil, myReviewAt: nil),
        ReviewPR(pr: pr(427, "Move order emails to the new queue", failed: 1, author: "john-doe", age: 3 * 86400),
                 requestedAt: Date(timeIntervalSinceNow: -26 * 3600), myReview: nil, myReviewAt: nil),
        ReviewPR(pr: pr(433, "Fix typos in the onboarding copy", author: "jane-doe", age: 1800),
                 requestedAt: Date(timeIntervalSinceNow: -1200), myReview: nil, myReviewAt: nil),
    ]
    static let reviewUpdated = [
        ReviewPR(pr: pr(409, "Split the orders service", author: "john-doe", age: 6 * 86400, newCommits: true),
                 requestedAt: nil, myReview: "APPROVED", myReviewAt: Date(timeIntervalSinceNow: -86400)),
        ReviewPR(pr: pr(402, "Dark mode for the dashboard", author: "jane-doe",
                        age: 9 * 86400, newCommits: true),
                 requestedAt: nil, myReview: "CHANGES_REQUESTED", myReviewAt: Date(timeIntervalSinceNow: -2 * 86400)),
    ]
}
