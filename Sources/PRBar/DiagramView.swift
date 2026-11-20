import SwiftUI

/// The Diagram tab: every agent as a card, with the subagents it started branching off below it,
/// and theirs below them. Links into a running subagent move, so you can see who is busy talking to whom.
struct DiagramView: View {
    let agents: [Store.LinkedAgent]
    let isFocused: (Agent) -> Bool

    var body: some View {
        // Idle agents with nothing running under them are just names; keep them out of the way.
        let trees = agents.filter { $0.agent.state != .idle || $0.agent.runningSubagents > 0 }
        let idle = agents.filter { !($0.agent.state != .idle || $0.agent.runningSubagents > 0) }
        VStack(alignment: .leading, spacing: 8) {
            if trees.isEmpty {
                EmptyLine(text: agents.isEmpty ? "No agents running" : "No agents working right now")
            }
            ForEach(trees) { AgentTree(linked: $0, focused: isFocused($0.agent)) }
            if !idle.isEmpty {
                Text("Idle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, trees.isEmpty ? 0 : 4)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(idle) { AgentRow(linked: $0, focused: isFocused($0.agent)) }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }
}

/// One main agent and the subagents under it, in a card.
private struct AgentTree: View {
    let linked: Store.LinkedAgent
    let focused: Bool

    private var agent: Agent { linked.agent }

    var body: some View {
        let rows = TreeRow.flatten(agent)
        VStack(alignment: .leading, spacing: 0) {
            AgentRow(linked: linked, focused: focused, countsSubagents: false)
                // The trunk out of the main agent's dot, down to its first subagent.
                .overlay(alignment: .topLeading) {
                    if !rows.isEmpty {
                        GeometryReader { g in
                            Path { p in
                                p.move(to: CGPoint(x: Layout.rootX, y: Layout.dotY + 7))
                                p.addLine(to: CGPoint(x: Layout.rootX, y: g.size.height))
                            }
                            .stroke(Layout.neutral, lineWidth: 1.2)
                        }
                        .allowsHitTesting(false)
                    }
                }
            ForEach(rows) { row in
                SubagentRow(row: row) { ChatOpener.open(agent) }
            }
        }
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Where the links go. The main agent's dot sits at `rootX`; each level of subagents is `step` further in.
private enum Layout {
    static let rootX: CGFloat = 18      // RowButton's 10pt padding plus half the 16pt dot frame
    static let dotY: CGFloat = 13
    static let step: CGFloat = 20
    static let rowHeight: CGFloat = 24
    static let neutral = Color.secondary.opacity(0.35)
    static let live = Indicator.working.color

    static func x(level: Int) -> CGFloat { rootX + CGFloat(level) * step }
}

/// A line of the tree, with what it needs to draw its links: which levels above it still
/// have siblings coming (so their line passes through), and whether it is the last child.
private struct TreeRow: Identifiable {
    enum Content { case subagent(Subagent), finished(Int) }

    let id: String
    let content: Content
    let depth: Int                  // 1 for the main agent's own subagents
    let continues: [Bool]           // per level 0..<depth-1: a later sibling still hangs off that level
    let isLast: Bool

    var running: Bool {
        if case .subagent(let s) = content { return s.running }
        return false
    }

    static func flatten(_ agent: Agent) -> [TreeRow] {
        let ids = Set(agent.subagents.map(\.id))
        var children: [String?: [Subagent]] = [:]
        for s in agent.subagents {
            // A parent that isn't shown hangs its children off the main agent.
            children[s.parentID.flatMap { ids.contains($0) ? $0 : nil }, default: []].append(s)
        }
        func ordered(_ list: [Subagent]) -> [Subagent] {
            list.sorted {
                $0.running != $1.running ? $0.running : ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
            }
        }

        var rows: [TreeRow] = []
        func walk(_ parent: String?, depth: Int, continues: [Bool], trailingPill: Bool) {
            let kids = ordered(children[parent] ?? [])
            for (i, s) in kids.enumerated() {
                let last = i == kids.count - 1 && !trailingPill
                rows.append(TreeRow(id: s.id, content: .subagent(s), depth: depth, continues: continues, isLast: last))
                walk(s.id, depth: depth + 1, continues: continues + [!last], trailingPill: false)
            }
        }
        let pill = agent.finishedSubagents > 0
        walk(nil, depth: 1, continues: [], trailingPill: pill)
        if pill {
            rows.append(TreeRow(id: "finished", content: .finished(agent.finishedSubagents), depth: 1, continues: [], isLast: true))
        }
        return rows
    }
}

private struct SubagentRow: View {
    let row: TreeRow
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Links(row: row)
                .frame(width: Layout.x(level: row.depth) - 8.5)   // centres the type chip under its link
            content
                .padding(.trailing, 10)
        }
        .frame(height: Layout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.primary.opacity(0.06) : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
    }

    @ViewBuilder private var content: some View {
        switch row.content {
        case .subagent(let s):
            HStack(spacing: 7) {
                TypeChip(subagent: s)
                Text(s.name)
                    .font(.system(size: 12, weight: s.running ? .medium : .regular))
                    .foregroundStyle(s.running ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let type = s.type {
                    Text(type).font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize()
                }
                Spacer(minLength: 6)
                if s.running {
                    Text(relativeTime(s.startedAt))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Layout.live)
                        .fixedSize()
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                        Text(relativeTime(s.lastActivity)).monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                }
            }
            .help([s.name, s.type.map { "\($0) agent" } ?? "Subagent",
                   s.running ? "Running for \(relativeTime(s.startedAt))" : "Finished \(relativeTime(s.lastActivity)) ago"]
                .joined(separator: "\n"))
        case .finished(let n):
            Text("\(n) finished subagent\(n == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 3)
            Spacer(minLength: 0)
        }
    }
}

/// The elbow into this row, plus the lines of the levels above passing through it.
private struct Links: View {
    let row: TreeRow
    @ObservedObject private var panel = PanelVisibility.shared

    var body: some View {
        if row.running {
            // Only rows with a running subagent animate, and only while the panel is on screen;
            // a closed panel would otherwise keep redrawing.
            TimelineView(.animation(minimumInterval: 1 / 24, paused: !panel.visible)) { context in
                canvas(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            canvas(phase: nil)
        }
    }

    private func canvas(phase: TimeInterval?) -> some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            let width: CGFloat = 1.2
            // Levels above: a straight line through, where that level has more children coming.
            for (level, more) in row.continues.enumerated() where more {
                var p = Path()
                p.move(to: CGPoint(x: Layout.x(level: level), y: 0))
                p.addLine(to: CGPoint(x: Layout.x(level: level), y: size.height))
                ctx.stroke(p, with: .color(Layout.neutral), lineWidth: width)
            }
            // This row's own level: the trunk goes on to later siblings.
            let x = Layout.x(level: row.depth - 1)
            if !row.isLast {
                var p = Path()
                p.move(to: CGPoint(x: x, y: mid))
                p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(Layout.neutral), lineWidth: width)
            }
            // The elbow: down from the parent, round the corner, into this node.
            var elbow = Path()
            elbow.move(to: CGPoint(x: x, y: 0))
            elbow.addLine(to: CGPoint(x: x, y: mid - 5))
            elbow.addQuadCurve(to: CGPoint(x: x + 5, y: mid), control: CGPoint(x: x, y: mid))
            elbow.addLine(to: CGPoint(x: size.width, y: mid))
            if let phase {
                ctx.stroke(elbow, with: .color(Layout.live.opacity(0.35)), lineWidth: width)
                // Dashes flowing from the parent into the subagent.
                ctx.stroke(elbow, with: .color(Layout.live),
                           style: StrokeStyle(lineWidth: width + 0.4, lineCap: .round, dash: [3, 5],
                                              dashPhase: -CGFloat(phase.truncatingRemainder(dividingBy: 1)) * 16))
            } else {
                ctx.stroke(elbow, with: .color(Layout.neutral), lineWidth: width)
            }
        }
    }
}

/// A small rounded square with the kind of subagent: a search, a skill, a web fetch, a fork…
private struct TypeChip: View {
    let subagent: Subagent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(subagent.running ? Layout.live : Color.secondary)
            .frame(width: 17, height: 17)
            .background(RoundedRectangle(cornerRadius: 4.5)
                .fill((subagent.running ? Layout.live : Color.secondary).opacity(subagent.running ? 0.16 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4.5)
                .strokeBorder((subagent.running ? Layout.live : Color.secondary).opacity(0.3), lineWidth: 0.5))
    }

    private var symbol: String {
        if subagent.name.hasPrefix("/") { return "wand.and.stars" }
        switch subagent.type?.lowercased() {
        case "explore": return "magnifyingglass"
        case "web-fetch": return "globe"
        case "fork": return "arrow.triangle.branch"
        case "plan": return "list.bullet"
        case "claude-code-guide": return "book"
        default: return "sparkle"
        }
    }
}
