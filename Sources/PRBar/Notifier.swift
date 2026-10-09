import AppKit
import UserNotifications

let notificationsEnabledKey = "notify.enabled"

/// Posts a macOS notification when something changes that needs you: an agent starts waiting on you
/// (or finishes), one of your PRs starts failing CI or gets conflicts, a review lands on your PR, or
/// someone requests your review. Only changes notify: whatever is already true when PRBar starts, or
/// when a PR or agent first shows up, stays quiet.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String, CaseIterable, Identifiable {
        case agentNeedsYou, agentFinished, prBroken, prReviewed, reviewRequested

        var id: String { rawValue }
        var key: String { "notify.\(rawValue)" }
        /// Agents finish turns all day, so that one is opt-in.
        var defaultOn: Bool { self != .agentFinished }

        var label: String {
            switch self {
            case .agentNeedsYou: return "Agent Needs You"
            case .agentFinished: return "Agent Finished"
            case .prBroken: return "My PR Fails CI or Has Conflicts"
            case .prReviewed: return "My PR Approved or Changes Requested"
            case .reviewRequested: return "Review Requested from Me"
            }
        }

        var isOn: Bool {
            let d = UserDefaults.standard
            return (d.object(forKey: notificationsEnabledKey) as? Bool ?? true) && (d.object(forKey: key) as? Bool ?? defaultOn)
        }
    }

    private let store: Store
    /// What the last update saw; nil until that source has loaded once, so startup stays quiet.
    private var agentStates: [String: AgentState] = [:]
    private var prs: [String: PullRequest]?
    /// Each PR's last known MERGEABLE or CONFLICTING, by key.
    private var mergeable: [String: String] = [:]
    private var requested: Set<String>?
    private var available = false

    init(store: Store) {
        self.store = store
    }

    func start() {
        // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
        guard Bundle.main.bundleIdentifier != nil else { return }
        available = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("PRBar: notification permission failed: \(error)") }
        }
    }

    /// Called after every store update; compares against the previous one.
    func update() {
        checkAgents()
        if store.githubUpdated != nil { checkPRs() }
        if store.githubUpdated != nil, store.reviewError == nil { checkReviewRequests() }
    }

    private func checkAgents() {
        var states: [String: AgentState] = [:]
        for linked in store.agents {
            let agent = linked.agent
            states[agent.id] = agent.state
            guard let old = agentStates[agent.id], old != agent.state else { continue }
            let context = linked.pr.map { "#\($0.number) \(cleanTitle($0.title))" } ?? agent.source
            if agent.state == .needsYou, Kind.agentNeedsYou.isOn {
                post(.agentNeedsYou, id: "agent-\(agent.id)", title: "Agent needs you", subtitle: context,
                     body: agent.name, info: ["agent": agent.id, "url": linked.pr?.url.absoluteString ?? ""])
            } else if old == .working, agent.state == .idle, Kind.agentFinished.isOn {
                post(.agentFinished, id: "agent-\(agent.id)", title: "Agent finished", subtitle: context,
                     body: agent.name, info: ["agent": agent.id, "url": linked.pr?.url.absoluteString ?? ""])
            }
        }
        agentStates = states
    }

    private func checkPRs() {
        let now = Dictionary(store.prs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let knownBefore = mergeable
        // GitHub answers UNKNOWN while it recomputes mergeability (e.g. on the first query in a while),
        // so keep the last known answer, or a long-conflicting PR "gets" conflicts again on every launch.
        mergeable = now.compactMapValues { $0.mergeable == "UNKNOWN" ? knownBefore[$0.key] : $0.mergeable }
        defer { prs = now }
        guard let before = prs else { return }
        for pr in store.prs {
            guard let old = before[pr.key] else { continue }
            let subtitle = "\(pr.repo.split(separator: "/").last ?? "")#\(pr.number)"

            var broken: [String] = []
            if pr.ci == .failing, old.ci != .failing {
                broken.append(pr.checksFailed == 1 ? "1 check failing" : "\(pr.checksFailed) checks failing")
            }
            if pr.mergeable == "CONFLICTING", knownBefore[pr.key] == "MERGEABLE" { broken.append("Merge conflicts") }
            if !broken.isEmpty, Kind.prBroken.isOn {
                post(.prBroken, id: "broken-\(pr.key)", title: broken.joined(separator: ", "), subtitle: subtitle,
                     body: cleanTitle(pr.title), info: ["url": pr.url.absoluteString])
            }

            if pr.reviewDecision != old.reviewDecision, Kind.prReviewed.isOn {
                let title: String? = switch pr.reviewDecision {
                case "APPROVED": "Approved"
                case "CHANGES_REQUESTED": "Changes requested"
                default: nil
                }
                if let title {
                    post(.prReviewed, id: "review-\(pr.key)", title: title, subtitle: subtitle,
                         body: cleanTitle(pr.title), info: ["url": pr.url.absoluteString])
                }
            }
        }
    }

    private func checkReviewRequests() {
        let now = Set(store.reviewRequested.map(\.id))
        defer { requested = now }
        guard let before = requested, Kind.reviewRequested.isOn else { return }
        for r in store.reviewRequested where !before.contains(r.id) {
            let pr = r.pr
            post(.reviewRequested, id: "requested-\(pr.key)", title: "Review requested by @\(pr.author)",
                 subtitle: "\(pr.repo.split(separator: "/").last ?? "")#\(pr.number)",
                 body: cleanTitle(pr.title), info: ["url": pr.url.absoluteString])
        }
    }

    /// The same `id` replaces an earlier notification about the same thing instead of stacking up.
    private func post(_ kind: Kind, id: String, title: String, subtitle: String, body: String, info: [String: String]) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = info
        content.threadIdentifier = kind.rawValue
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while the panel has focus.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Clicking opens the agent's chat, like its row in the panel, or the PR in the browser.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let agentID = info["agent"] as? String
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        DispatchQueue.main.async { [store] in
            if let agentID, let agent = store.agents.first(where: { $0.agent.id == agentID })?.agent {
                ChatOpener.open(agent)
            } else if let url {
                Browser.open(url, activate: true)
            }
        }
        completionHandler()
    }
}

/// Opens PRBar's page in System Settings → Notifications, where macOS keeps the banner style and permission.
func openNotificationSettings() {
    let id = Bundle.main.bundleIdentifier ?? ""
    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
        NSWorkspace.shared.open(url)
    }
}
