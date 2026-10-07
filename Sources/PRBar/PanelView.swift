import AppKit
import SwiftUI

/// The panel shown from the menu bar icon. Clicking rows opens links in the background,
/// so the panel stays open and several PRs can be opened in a row.
struct PanelView: View {
    enum Tab: String { case mine, review }

    @ObservedObject var store: Store
    @ObservedObject var updater: Updater
    @AppStorage("tab") private var tab: Tab = .mine
    /// Section ids the user folded away, comma-separated.
    @AppStorage("collapsedSections") private var collapsed = ""
    @State private var contentHeight: CGFloat = 0

    private let maxHeight: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .mine: mine
                    case .review: review
                    }
                }
                .padding(.bottom, 6)
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(max(contentHeight, 44), maxHeight))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }

            Divider()
            footer
        }
        .frame(width: 400)
    }

    private var header: some View {
        HStack {
            Text("PRBar").font(.system(size: 13, weight: .semibold))
            Spacer()
            TabSwitch(tab: $tab, reviewCount: store.reviewRequested.count)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: Tabs

    @ViewBuilder private var mine: some View {
        if store.ready.isEmpty && store.drafts.isEmpty {
            EmptyLine(text: store.githubUpdated == nil ? "Loading…" : "No open pull requests")
        }
        if !store.ready.isEmpty {
            section("ready", "Ready for review", store.ready.count, divider: false) {
                ForEach(store.ready) { PRRow(row: $0) }
            }
        }
        if !store.drafts.isEmpty {
            section("drafts", "Drafts", store.drafts.count, divider: !store.ready.isEmpty) {
                ForEach(store.drafts) { PRRow(row: $0) }
            }
        }
        if !store.agents.isEmpty {
            section("agents", "Agents", store.agents.count, divider: true) {
                ForEach(store.agents) { AgentRow(linked: $0) }
            }
        }
    }

    @ViewBuilder private var review: some View {
        if store.reviewRequested.isEmpty && store.reviewUpdated.isEmpty {
            EmptyLine(text: store.githubUpdated == nil ? "Loading…" : "Nothing waiting for your review")
        }
        if !store.reviewRequested.isEmpty {
            section("requested", "Requested from you", store.reviewRequested.count, divider: false) {
                ForEach(store.reviewRequested) { ReviewRow(item: $0, requested: true) }
            }
        }
        if !store.reviewUpdated.isEmpty {
            section("updated", "Updated since your review", store.reviewUpdated.count, divider: !store.reviewRequested.isEmpty) {
                ForEach(store.reviewUpdated) { ReviewRow(item: $0, requested: false) }
            }
        }
    }

    private func section<Rows: View>(_ id: String, _ title: String, _ count: Int, divider: Bool,
                                     @ViewBuilder rows: () -> Rows) -> some View {
        let folded = collapsed.split(separator: ",").contains(Substring(id))
        return VStack(alignment: .leading, spacing: 0) {
            if divider { Divider().padding(.horizontal, 16).padding(.top, 6) }
            SectionHeader(title: title, count: count, folded: folded) {
                var ids = collapsed.split(separator: ",").map(String.init).filter { $0 != id }
                if !folded { ids.append(id) }
                collapsed = ids.joined(separator: ",")
            }
            if !folded { rows().padding(.horizontal, 6) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let version = updater.available { UpdateLine(updater: updater, version: version) }
            if let e = store.githubError { ErrorLine(source: "GitHub", message: e) }
            if tab == .review, let e = store.reviewError { ErrorLine(source: "Reviews", message: e) }
            if let e = store.cloudError { ErrorLine(source: "Cloud", message: e) }
            HStack(spacing: 12) {
                Text("Updated \(store.githubUpdated.map { relativeTime($0) + " ago" } ?? "—")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { store.refreshAll(); updater.check() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r")
                    .help("Refresh now (⌘R)")
                Menu {
                    if isHomebrewInstall {
                        // A login item would point into the versioned Cellar path; brew services survives upgrades.
                        Button("Copy “brew services start prbar” (open at login)") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew services start prbar", forType: .string)
                        }
                    } else {
                        Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: { store.setOpenAtLogin($0) }))
                    }
                    Divider()
                    Button("Quit PRBar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

/// The symbols and colors shared by the panel and the menu bar, so the two always match.
enum Indicator {
    case needsYou, working, idle, passing, failing, ready, draft

    var symbol: String {
        switch self {
        case .needsYou: return "circle.lefthalf.filled"
        case .working: return "circle.fill"
        case .idle: return "circle"
        case .passing: return "checkmark.circle.fill"
        case .failing: return "xmark.circle.fill"
        case .ready, .draft: return "arrow.triangle.pull"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .needsYou: return .systemOrange
        case .ready: return .systemGreen
        case .draft: return .systemGray
        case .working, .passing: return .systemGreen
        case .idle: return .tertiaryLabelColor
        case .failing: return .systemRed
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Symbols with a glyph inside the circle (✗, pencil), which needs a second color to show.
    var hasGlyph: Bool { self == .passing || self == .failing }

    init(_ state: AgentState) {
        switch state {
        case .needsYou: self = .needsYou
        case .working: self = .working
        case .idle: self = .idle
        }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// "Mine | Review 3" in the header.
private struct TabSwitch: View {
    @Binding var tab: PanelView.Tab
    let reviewCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(.mine) { Text("Mine") }
            segment(.review) {
                HStack(spacing: 5) {
                    Text("Review")
                    if reviewCount > 0 {
                        Text(verbatim: "\(reviewCount)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Circle().fill(Color.blue))
                    }
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .help(reviewCount > 0 ? "\(reviewCount) PR\(reviewCount == 1 ? "" : "s") waiting for your review" : "")
    }

    private func segment<Label: View>(_ value: PanelView.Tab, @ViewBuilder label: () -> Label) -> some View {
        Button { tab = value } label: {
            label()
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tab == value ? .primary : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(tab == value ? Color.primary.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A foldable section title with its count.
private struct SectionHeader: View {
    let title: String
    let count: Int
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(folded ? -90 : 0))
                .frame(width: 10)
            Text(title).font(.system(size: 11.5, weight: .medium))
            Spacer()
            Text(verbatim: "\(count)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 17)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

private struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}

/// Hover highlight plus a click action, shared by every row.
private struct RowButton: ViewModifier {
    let action: () -> Void
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovered ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
    }
}

/// A status on a row's second line: a colored dot and label, or plain grey text without a dot.
private struct Tag: Hashable {
    let text: String
    var color: Color? = nil
}

/// Title on top, "#123 ● Conflicts ● 1 failing" below, shared by your PRs and the review queue.
private struct PRLines: View {
    let pr: PullRequest
    let tags: [Tag]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cleanTitle(pr.title))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 7) {
                Text(verbatim: "#\(pr.number)").monospacedDigit().foregroundStyle(.secondary)
                ForEach(tags, id: \.self) { tag in
                    if let color = tag.color {
                        HStack(spacing: 4) {
                            Circle().fill(color).frame(width: 5, height: 5)
                            Text(tag.text).foregroundStyle(color)
                        }
                    } else {
                        Text(tag.text).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
        }
    }
}

private struct CIIcon: View {
    let ci: PullRequest.CI

    var body: some View {
        Group {
            switch ci {
            case .passing: Image(systemName: Indicator.passing.symbol).foregroundStyle(.white, Indicator.passing.color)
            case .failing: Image(systemName: Indicator.failing.symbol).foregroundStyle(.white, Indicator.failing.color)
            case .pending: Image(systemName: "clock.fill").foregroundStyle(.yellow)
            case .none: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 14))
        .frame(width: 16)
        .padding(.top, 1)
    }
}

/// CI and merge problems, shared by both tabs.
private func problemTags(_ pr: PullRequest) -> [Tag] {
    var tags: [Tag] = []
    if pr.checksFailed > 0 { tags.append(Tag(text: "\(pr.checksFailed) failing", color: Indicator.failing.color)) }
    if pr.checksPending > 0 { tags.append(Tag(text: "\(pr.checksPending) running", color: .yellow)) }
    if pr.mergeable == "CONFLICTING" { tags.append(Tag(text: "Conflicts", color: Indicator.failing.color)) }
    return tags
}

private struct PRRow: View {
    let row: Store.Row

    private var pr: PullRequest { row.pr }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CIIcon(ci: pr.ci)
            PRLines(pr: pr, tags: tags)
            Spacer(minLength: 6)
            if let chat = row.latestChat { ChatButton(agent: chat) }
        }
        .modifier(RowButton { Browser.open(pr.url) })
        .help(([pr.repo + " · " + pr.headRef, pr.title] + row.agents.map { "\($0.source) agent: \($0.name)" })
            .joined(separator: "\n"))
    }

    /// Only what needs attention; a PR with nothing in the way says it's ready to merge.
    private var tags: [Tag] {
        var tags = problemTags(pr)
        if pr.reviewDecision == "CHANGES_REQUESTED" { tags.append(Tag(text: "Changes requested", color: .orange)) }
        if pr.unresolvedThreads > 0 { tags.append(Tag(text: "\(pr.unresolvedThreads) unresolved", color: .orange)) }
        let blocked = !tags.isEmpty
        if pr.reviewDecision == "APPROVED" && blocked { tags.append(Tag(text: "Approved", color: .green)) }

        // The most urgent agent on this PR; idle agents don't get a tag.
        switch row.agents.map(\.state).min() {
        case .needsYou: tags.append(Tag(text: "Agent needs you", color: Indicator.needsYou.color))
        case .working: tags.append(Tag(text: "Agent working", color: Indicator.working.color))
        default: break
        }

        if !blocked && !pr.isDraft && pr.ci != .pending {
            if pr.reviewDecision == "REVIEW_REQUIRED" {
                tags.append(Tag(text: "Awaiting review"))
            } else if pr.mergeable == "MERGEABLE" {
                tags.append(Tag(text: "Ready to merge"))
            }
        }
        return tags
    }
}

private struct ReviewRow: View {
    let item: ReviewPR
    /// In "Requested from you", rather than "Updated since your review".
    let requested: Bool

    private var pr: PullRequest { item.pr }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CIIcon(ci: pr.ci)
            PRLines(pr: pr, tags: tags)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                Avatar(login: pr.author)
                Text(relativeTime(pr.createdAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 1)
        }
        .modifier(RowButton { Browser.open(pr.url) })
        .help("\(pr.repo) · @\(pr.author) · opened \(relativeTime(pr.createdAt)) ago\n\(pr.title)")
    }

    private var tags: [Tag] {
        var tags: [Tag] = []
        if requested {
            if let at = item.requestedAt {
                // Over a day without a review is worth a nudge.
                tags.append(Tag(text: "Waiting \(relativeTime(at))", color: -at.timeIntervalSinceNow > 86400 ? .orange : .secondary))
            }
        } else {
            tags.append(Tag(text: "New commits", color: .blue))
            switch item.myReview {
            case "APPROVED": tags.append(Tag(text: "Approved by you", color: .green))
            case "CHANGES_REQUESTED": tags.append(Tag(text: "You requested changes", color: .orange))
            default: break
            }
        }
        return tags + problemTags(pr)
    }
}

/// The PR author's initials on a color picked from their login, so the same person keeps the same color.
private struct Avatar: View {
    let login: String

    var body: some View {
        Text(initials)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color))
            .help("@\(login)")
    }

    private var initials: String {
        let parts = login.split(whereSeparator: { "-_.".contains($0) })
        let letters = parts.count > 1 ? parts.prefix(2).compactMap(\.first) : Array(login.prefix(2))
        return String(letters).uppercased()
    }

    private var color: Color {
        let hue = Double(login.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        return Color(hue: hue, saturation: 0.45, brightness: 0.62)
    }
}

/// Opens the most recent agent chat on a PR, wherever it lives.
private struct ChatButton: View {
    let agent: Agent
    @State private var hovered = false

    var body: some View {
        Button { ChatOpener.open(agent) } label: {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left").font(.system(size: 10, weight: .medium))
                Text("Chat").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Color.blue)
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(Capsule().fill(Color.blue.opacity(hovered ? 0.24 : 0.14)))
            .overlay(Capsule().strokeBorder(Color.blue.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Open latest chat: \(agent.name)\n\(agent.source)\(stateText) · \(relativeTime(agent.lastActivity)) ago\n\(ChatOpener.destination(for: agent))")
    }

    private var stateText: String {
        switch agent.state {
        case .working: return ", working"
        case .needsYou: return ", needs you"
        case .idle: return ""
        }
    }
}

private struct AgentRow: View {
    let linked: Store.LinkedAgent

    private var agent: Agent { linked.agent }
    private var indicator: Indicator { Indicator(agent.state) }
    private var idle: Bool { agent.state == .idle }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dot.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 13, weight: idle ? .regular : .medium))
                    .foregroundStyle(idle ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing.font(.system(size: 11, weight: idle ? .regular : .medium)).padding(.top, 1)
        }
        .modifier(RowButton { ChatOpener.open(agent) })
        .help([agent.name, agent.detail, ChatOpener.destination(for: agent)].compactMap { $0 }.joined(separator: "\n\n"))
    }

    /// Working and waiting agents get a soft halo, so they stand out from the idle rings.
    @ViewBuilder private var dot: some View {
        if idle {
            Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5).frame(width: 7, height: 7)
        } else {
            ZStack {
                Circle().fill(indicator.color.opacity(0.22)).frame(width: 14, height: 14)
                Circle().fill(indicator.color).frame(width: 7, height: 7)
            }
        }
    }

    /// "#973 · CLI"; active agents add their time here, since the right side says what they're doing.
    private var subtitle: String {
        var parts = [linked.pr.map { "#\($0.number)" }, agent.source].compactMap { $0 }
        if !idle { parts.append(relativeTime(agent.lastActivity)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        switch agent.state {
        case .working: Text("Working").foregroundStyle(indicator.color)
        case .needsYou: Text("Needs you").foregroundStyle(indicator.color)
        case .idle: Text(relativeTime(agent.lastActivity)).monospacedDigit().foregroundStyle(.tertiary)
        }
    }
}

private struct UpdateLine: View {
    @ObservedObject var updater: Updater
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("Update available: v\(version)")
                    .font(.caption.weight(.medium))
                Text("(you have v\(updater.current))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if updater.state == .updating {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(isHomebrewInstall ? "Update" : "View") { updater.update() }
                        .controlSize(.small)
                        .help(isHomebrewInstall
                              ? "Runs brew upgrade prbar and restarts PRBar"
                              : "Opens the install instructions on GitHub")
                }
            }
            if case .failed(let message) = updater.state {
                ErrorLine(source: "Update", message: message)
            }
        }
        .padding(.bottom, 2)
    }
}

private struct ErrorLine: View {
    let source: String
    let message: String

    var body: some View {
        Label("\(source): \(message)", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(2)
    }
}

let isHomebrewInstall = Bundle.main.bundlePath.contains("/Cellar/") || Bundle.main.bundlePath.contains("/opt/prbar/")

/// …/Cellar/prbar/0.1.4/PRBar.app → …/opt/prbar/PRBar.app, which always points at the newest version.
let stableAppPath = Bundle.main.bundlePath.replacingOccurrences(
    of: #"/Cellar/prbar/[^/]+/"#, with: "/opt/prbar/", options: .regularExpression)

/// Opens the link without bringing the browser to the front, so the panel keeps focus.
func openInBackground(_ url: URL) {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    NSWorkspace.shared.open(url, configuration: config)
}

/// Strips the "[staging] BLI-1637 |" prefix convention so the description is what shows.
func cleanTitle(_ title: String) -> String {
    title.replacingOccurrences(of: #"^(\[[^\]]+\]\s*)?([A-Z]+-\d+\s*)*\|\s*"#, with: "", options: .regularExpression)
}
