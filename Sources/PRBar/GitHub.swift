import Foundation

/// Fetches the viewer's open PRs and review queue across all repos with `gh api graphql`.
enum GitHub {
    /// The fields every PR row needs, shared by your own PRs and the review queue.
    private static let fields = """
    fragment pr on PullRequest {
      number title url isDraft headRefName reviewDecision mergeable createdAt
      author { login }
      repository { nameWithOwner }
      reviewThreads(first: 100) { nodes { isResolved } }
      commits(last: 1) { nodes { commit { committedDate statusCheckRollup { contexts(first: 100) { nodes {
        __typename
        ... on CheckRun { status conclusion }
        ... on StatusContext { state }
      } } } } } }
    }
    """

    private static let query = """
    query { viewer { pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } } } }
    \(fields)
    """

    /// Other people's PRs: the ones asking for your review, and the ones you reviewed that got new commits since.
    private static let reviewQuery = """
    query {
      viewer { login }
      requested: search(query: "is:pr is:open archived:false draft:false review-requested:@me", type: ISSUE, first: 30) { nodes { ...pr ...review } }
      reviewed: search(query: "is:pr is:open archived:false draft:false reviewed-by:@me -author:@me", type: ISSUE, first: 30) { nodes { ...pr ...review } }
    }
    fragment review on PullRequest {
      timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 1) { nodes { ... on ReviewRequestedEvent { createdAt } } }
      latestReviews(first: 30) { nodes { author { login } state submittedAt } }
    }
    \(fields)
    """

    static func fetchOpenPRs() throws -> [PullRequest] {
        let data = try Shell.run(["gh", "api", "graphql", "-f", "query=\(query)"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let viewer = (root["data"] as? [String: Any])?["viewer"] as? [String: Any],
              let nodes = (viewer["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]
        else { throw Shell.Failure(description: "unexpected GitHub response") }
        return nodes.compactMap(pullRequest)
    }

    static func fetchReviewQueue() throws -> (requested: [ReviewPR], updated: [ReviewPR]) {
        let data = try Shell.run(["gh", "api", "graphql", "-f", "query=\(reviewQuery)"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let login = (d["viewer"] as? [String: Any])?["login"] as? String
        else { throw Shell.Failure(description: "unexpected GitHub response") }

        func nodes(_ key: String) -> [[String: Any]] {
            ((d[key] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        }
        func reviewPR(_ n: [String: Any]) -> ReviewPR? {
            guard let pr = pullRequest(n) else { return nil }
            let requests = ((n["timelineItems"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let reviews = ((n["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            let mine = reviews.first { ($0["author"] as? [String: Any])?["login"] as? String == login }
            return ReviewPR(
                pr: pr,
                requestedAt: parseISO(requests.last?["createdAt"] as? String),
                myReview: mine?["state"] as? String,
                myReviewAt: parseISO(mine?["submittedAt"] as? String)
            )
        }

        let requested = nodes("requested").compactMap(reviewPR)
        let requestedKeys = Set(requested.map(\.pr.key))
        let updated = nodes("reviewed").compactMap(reviewPR).filter {
            !requestedKeys.contains($0.pr.key) && $0.hasNewCommits
        }
        return (requested, updated)
    }

    private static func pullRequest(_ n: [String: Any]) -> PullRequest? {
        guard let number = n["number"] as? Int,
              let urlString = n["url"] as? String, let url = URL(string: urlString) else { return nil }

        let threads = ((n["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let commit = (((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]) as? [String: Any]
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let contexts = ((rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []

        var passed = 0, failed = 0, pending = 0
        for c in contexts {
            if c["__typename"] as? String == "CheckRun" {
                if c["status"] as? String != "COMPLETED" { pending += 1; continue }
                switch c["conclusion"] as? String {
                case "SUCCESS", "SKIPPED", "NEUTRAL": passed += 1
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": failed += 1
                default: pending += 1
                }
            } else {
                switch c["state"] as? String {
                case "SUCCESS": passed += 1
                case "FAILURE", "ERROR": failed += 1
                default: pending += 1
                }
            }
        }

        return PullRequest(
            repo: (n["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? "",
            number: number,
            title: n["title"] as? String ?? "",
            url: url,
            isDraft: n["isDraft"] as? Bool ?? false,
            headRef: n["headRefName"] as? String ?? "",
            reviewDecision: n["reviewDecision"] as? String,
            mergeable: n["mergeable"] as? String ?? "UNKNOWN",
            unresolvedThreads: threads.filter { ($0["isResolved"] as? Bool) == false }.count,
            checksPassed: passed,
            checksFailed: failed,
            checksPending: pending,
            author: (n["author"] as? [String: Any])?["login"] as? String ?? "",
            createdAt: parseISO(n["createdAt"] as? String),
            lastCommitAt: parseISO(commit?["committedDate"] as? String)
        )
    }
}
