import Foundation

/// Fetches the viewer's open PRs across all repos with one `gh api graphql` call.
enum GitHub {
    private static let query = """
    query { viewer { pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes {
      number title url isDraft headRefName reviewDecision mergeable
      repository { nameWithOwner }
      reviewThreads(first: 100) { nodes { isResolved } }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
        __typename
        ... on CheckRun { status conclusion }
        ... on StatusContext { state }
      } } } } } }
    } } } }
    """

    static func fetchOpenPRs() throws -> [PullRequest] {
        let data = try Shell.run(["gh", "api", "graphql", "-f", "query=\(query)"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let viewer = (root["data"] as? [String: Any])?["viewer"] as? [String: Any],
              let nodes = (viewer["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]
        else { throw Shell.Failure(description: "unexpected GitHub response") }

        return nodes.compactMap { n in
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
                checksPending: pending
            )
        }
    }
}
