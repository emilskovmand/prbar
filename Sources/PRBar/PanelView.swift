import AppKit
import SwiftUI

/// The panel shown from the menu bar icon. Clicking rows opens links in the background,
/// so the panel stays open and several PRs can be opened in a row.
struct PanelView: View {
    @ObservedObject var store: Store
    @State private var contentHeight: CGFloat = 0

    private let maxHeight: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
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

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.ready.isEmpty && store.drafts.isEmpty {
                Text(store.githubUpdated == nil ? "Loading…" : "No open pull requests")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            section("Ready for review", .ready, store.ready)
            section("Drafts", .draft, store.drafts)
            if !store.agents.isEmpty {
                SectionHeader(title: "Agents", count: store.agents.count)
                ForEach(store.agents) { AgentRow(linked: $0).padding(.horizontal, 6) }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func section(_ title: String, _ indicator: Indicator, _ rows: [Store.Row]) -> some View {
        if !rows.isEmpty {
            SectionHeader(title: title, count: rows.count, indicator: indicator)
            ForEach(rows) { PRRow(row: $0).padding(.horizontal, 6) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = store.githubError { ErrorLine(source: "GitHub", message: e) }
            if let e = store.cloudError { ErrorLine(source: "Cloud", message: e) }
            HStack(spacing: 10) {
                Text("Updated \(store.githubUpdated.map { relativeTime($0) + " ago" } ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
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
                    Toggle("Open finished Claude chats in Claude Desktop", isOn: Binding(
                        get: { store.preferDesktop },
                        set: { store.preferDesktop = $0 }
                    ))
                    Divider()
                    Button("Quit PRBar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

private struct SectionHeader: View {
    let title: String
    let count: Int
    var indicator: Indicator? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let indicator {
                // Same icon as the menu bar count for this section.
                Image(systemName: indicator.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(indicator.color)
            }
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
            Spacer()
            Text("\(count)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// Hover highlight plus a click action, shared by PR and agent rows.
private struct RowButton: ViewModifier {
    let action: () -> Void
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovered ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
    }
}

private struct PRRow: View {
    let row: Store.Row

    private var pr: PullRequest { row.pr }

    /// The most urgent state among the agents on this PR; idle agents don't get a dot.
    private var agentIndicator: Indicator? {
        guard let top = row.agents.map(\.state).min(), top != .idle else { return nil }
        return Indicator(top)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ciIcon.frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(cleanTitle(pr.title))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let chat = row.latestChat { ChatButton(agent: chat) }
                    if let agentIndicator {
                        Image(systemName: agentIndicator.symbol)
                            .font(.system(size: 8))
                            .foregroundStyle(agentIndicator.color)
                    }
                    Text("#\(pr.number)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let facts { facts.font(.caption) }
            }
        }
        .modifier(RowButton { openInBackground(pr.url) })
        .help(([pr.repo + " · " + pr.headRef, pr.title] + row.agents.map { "\($0.source) agent: \($0.name)" })
            .joined(separator: "\n"))
    }

    @ViewBuilder private var ciIcon: some View {
        switch pr.ci {
        case .passing: Image(systemName: Indicator.passing.symbol).foregroundStyle(Indicator.passing.color)
        case .failing: Image(systemName: Indicator.failing.symbol).foregroundStyle(Indicator.failing.color)
        case .pending: Image(systemName: "clock.fill").foregroundStyle(.yellow)
        case .none: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        }
    }

    /// Only what needs attention; a healthy PR gets no second line.
    private var facts: Text? {
        var parts: [Text] = []
        if pr.checksFailed > 0 { parts.append(Text("\(pr.checksFailed) failing").foregroundColor(Indicator.failing.color)) }
        if pr.checksPending > 0 { parts.append(Text("\(pr.checksPending) running")) }
        if pr.mergeable == "CONFLICTING" { parts.append(Text("conflicts").foregroundColor(.red)) }
        switch pr.reviewDecision {
        case "CHANGES_REQUESTED":
            parts.append(Text("changes requested").foregroundColor(.orange))
        case "APPROVED": parts.append(Text("approved").foregroundColor(.green))
        default: break
        }
        if pr.unresolvedThreads > 0 { parts.append(Text("\(pr.unresolvedThreads) unresolved")) }
        guard let first = parts.first else { return nil }
        return parts.dropFirst()
            .reduce(first) { $0 + Text(" · ") + $1 }
            .foregroundColor(.secondary)
    }
}

/// Opens the most recent agent chat on a PR, wherever it lives.
private struct ChatButton: View {
    let agent: Agent
    @State private var hovered = false

    var body: some View {
        Button { ChatOpener.open(agent) } label: {
            Image(systemName: "text.bubble")
                .font(.callout)
                .foregroundStyle(hovered ? .primary : .secondary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Color.primary.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open latest chat: \(agent.name)\n\(agent.source)\(stateText) · \(relativeTime(agent.lastActivity)) ago\n\(destination)")
    }

    private var stateText: String {
        switch agent.state {
        case .working: return ", working"
        case .needsYou: return ", needs you"
        case .idle: return ""
        }
    }

    private var destination: String {
        switch agent.kind {
        case .codex: return "Opens in Codex"
        case .cloud: return "Opens on claude.ai"
        case .local:
            if agent.running { return "Switches to its terminal tab" }
            return agent.source == "Desktop" || ChatOpener.preferDesktop ? "Opens in Claude Desktop" : "Resumes in a new terminal window"
        }
    }
}

private struct AgentRow: View {
    let linked: Store.LinkedAgent
    @State private var copied = false

    private var agent: Agent { linked.agent }
    private var indicator: Indicator { Indicator(agent.state) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: indicator.symbol)
                .font(.system(size: 8))
                .foregroundStyle(indicator.color)
                .frame(width: 16)
            Text(agent.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(agent.state == .idle ? .secondary : .primary)
            Spacer(minLength: 4)
            trailing
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .modifier(RowButton(action: activate))
        .help([agent.name, agent.detail, hint].compactMap { $0 }.joined(separator: "\n\n"))
    }

    private var trailing: Text {
        var parts: [Text] = []
        switch agent.state {
        case .needsYou: parts.append(Text("needs you").foregroundColor(indicator.color))
        case .working: parts.append(Text("working").foregroundColor(indicator.color))
        case .idle: break
        }
        if copied { parts.append(Text("copied")) }
        if let pr = linked.pr { parts.append(Text("#\(pr.number)")) }
        parts.append(Text(agent.source))
        parts.append(Text(relativeTime(agent.lastActivity)).monospacedDigit())
        return parts.dropFirst().reduce(parts[0]) { $0 + Text(" · ") + $1 }
    }

    private var hint: String? {
        if agent.kind == .codex, agent.openURL != nil { return "Click to open in Codex" }
        if agent.openURL != nil { return "Click to open in claude.ai" }
        if agent.resumeCommand != nil { return "Click to copy the resume command" }
        return nil
    }

    private func activate() {
        if let url = agent.openURL, agent.kind == .codex {
            // Jumping to a Codex chat means switching to Codex, so bring it to the front.
            NSWorkspace.shared.open(url)
        } else if let url = agent.openURL {
            openInBackground(url)
        } else if let cmd = agent.resumeCommand {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
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
