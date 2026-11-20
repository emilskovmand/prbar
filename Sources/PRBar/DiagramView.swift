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

    @State private var rootHeight: CGFloat = 44

    private var agent: Agent { linked.agent }

    var body: some View {
        let rows = TreeRow.flatten(agent)
        VStack(alignment: .leading, spacing: 0) {
            AgentRow(linked: linked, focused: focused, countsSubagents: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rootHeight = $0 }
                // The trunk out of the main agent's dot, down to its first subagent.
                .background {
                    if !rows.isEmpty {
                        let live = rows.filter { $0.depth == 1 }.map(\.activity).max() ?? .none
                        FlowCanvas(animated: live != .none) { ctx, size, time in
                            let top = Layout.dotY + 7
                            var p = Path()
                            p.move(to: CGPoint(x: Layout.rootX, y: top))
                            p.addLine(to: CGPoint(x: Layout.rootX, y: size.height))
                            Flow.stroke(ctx, p, live: live, start: top, time: time)
                        }
                    }
                }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                // How far down the tree this row starts, so the dashes run on from the row above.
                SubagentRow(row: row, offset: rootHeight + CGFloat(i) * Layout.rowHeight) { ChatOpener.open(agent) }
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
    static let watching = Indicator.watching.color

    static func color(_ a: Subagent.Activity) -> Color { a == .watching ? watching : live }

    static func x(level: Int) -> CGFloat { rootX + CGFloat(level) * step }
}

/// Moving dashes along every link between an agent and a running subagent.
private enum Flow {
    static let period: CGFloat = 8      // the dash pattern's length: 3 on, 5 off
    static let speed: Double = 16       // points per second, flowing from parent to child
    static let watchingSpeed: Double = 5   // a subagent waiting on a shell: a slow, blue flow

    /// `start` is how far down the tree the path begins; the dash pattern is laid out from the top of
    /// the tree, so pieces drawn in different rows join into one line of dashes.
    static func stroke(_ ctx: GraphicsContext, _ path: Path, live: Subagent.Activity, start: CGFloat, time: TimeInterval?) {
        guard live != .none else {
            ctx.stroke(path, with: .color(Layout.neutral), lineWidth: 1.2)
            return
        }
        let color = Layout.color(live)
        ctx.stroke(path, with: .color(color.opacity(0.35)), lineWidth: 1.2)
        let rate = live == .watching ? watchingSpeed : speed
        let flowed = CGFloat(((time ?? 0) * rate).truncatingRemainder(dividingBy: Double(period)))
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3, period - 3],
                                      dashPhase: start.truncatingRemainder(dividingBy: period) - flowed))
    }
}

/// A Canvas that redraws every frame while `animated` and the panel is on screen; a closed panel
/// would otherwise keep redrawing.
private struct FlowCanvas: View {
    let animated: Bool
    let draw: (GraphicsContext, CGSize, TimeInterval?) -> Void
    @ObservedObject private var panel = PanelVisibility.shared

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 24, paused: !panel.visible)) { context in
                Canvas { ctx, size in draw(ctx, size, context.date.timeIntervalSinceReferenceDate) }
            }
            .allowsHitTesting(false)
        } else {
            Canvas { ctx, size in draw(ctx, size, nil) }.allowsHitTesting(false)
        }
    }
}

/// A line of the tree, with what it needs to draw its links: which levels above it still
/// have siblings coming (so their line passes through), whether it is the last child, and
/// which of those lines lead on to a running subagent.
private struct TreeRow: Identifiable {
    enum Content { case subagent(Subagent), finished(Int) }

    let id: String
    let content: Content
    let depth: Int                  // 1 for the main agent's own subagents
    let continues: [Bool]           // per level 0..<depth-1: a later sibling still hangs off that level
    let isLast: Bool
    // How busy each line is: the busiest running subagent it leads to.
    var passesLive: [Subagent.Activity] = []    // per level 0..<depth-1: later siblings at that level
    var laterRunning: Subagent.Activity = .none // later siblings at this row's own level
    var hasChildren = false
    var childRunning: Subagent.Activity = .none

    var activity: Subagent.Activity {
        if case .subagent(let s) = content { return s.activity }
        return .none
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
        func walk(_ parent: String?, depth: Int, continues: [Bool], passesLive: [Subagent.Activity], trailingPill: Bool) {
            let kids = ordered(children[parent] ?? [])
            for (i, s) in kids.enumerated() {
                let last = i == kids.count - 1 && !trailingPill
                let laterRunning = kids[(i + 1)...].map(\.activity).max() ?? .none
                let own = children[s.id] ?? []
                rows.append(TreeRow(id: s.id, content: .subagent(s), depth: depth, continues: continues, isLast: last,
                                    passesLive: passesLive, laterRunning: laterRunning,
                                    hasChildren: !own.isEmpty, childRunning: own.map(\.activity).max() ?? .none))
                walk(s.id, depth: depth + 1, continues: continues + [!last], passesLive: passesLive + [laterRunning],
                     trailingPill: false)
            }
        }
        let pill = agent.finishedSubagents > 0
        walk(nil, depth: 1, continues: [], passesLive: [], trailingPill: pill)
        if pill {
            rows.append(TreeRow(id: "finished", content: .finished(agent.finishedSubagents), depth: 1, continues: [], isLast: true))
        }
        return rows
    }
}

private struct SubagentRow: View {
    let row: TreeRow
    let offset: CGFloat
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Layout.x(level: row.depth) - 8.5)   // centres the type chip under its link
            content
                .padding(.trailing, 10)
        }
        .frame(height: Layout.rowHeight)
        .background(alignment: .leading) { Links(row: row, offset: offset) }
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
                if s.watching {
                    // Waiting on a shell command, like a main agent that's watching one.
                    Text("Watching \(relativeTime(s.startedAt))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Layout.watching)
                        .fixedSize()
                } else if s.running {
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
                   s.watching ? "Waiting on a shell command · started \(relativeTime(s.startedAt)) ago"
                   : s.running ? "Running for \(relativeTime(s.startedAt))" : "Finished \(relativeTime(s.lastActivity)) ago"]
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

/// The links drawn in one row: the lines of the levels above passing through, the elbow from
/// the parent into this subagent, the line on to its later siblings, and the line down to its own
/// subagents. Each animates when it leads to a running subagent.
private struct Links: View {
    let row: TreeRow
    let offset: CGFloat

    private var animated: Bool {
        ([row.activity, row.laterRunning, row.childRunning] + row.passesLive).contains { $0 != .none }
    }

    var body: some View {
        FlowCanvas(animated: animated) { ctx, size, time in
            let mid = size.height / 2
            let corner: CGFloat = 5
            func line(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat, live: Subagent.Activity) {
                var p = Path()
                p.move(to: CGPoint(x: x, y: y0))
                p.addLine(to: CGPoint(x: x, y: y1))
                Flow.stroke(ctx, p, live: live, start: offset + y0, time: time)
            }

            for (level, more) in row.continues.enumerated() where more {
                line(Layout.x(level: level), from: 0, to: size.height, live: row.passesLive[level])
            }

            let x = Layout.x(level: row.depth - 1)
            line(x, from: 0, to: mid - corner, live: max(row.activity, row.laterRunning))
            if !row.isLast {
                line(x, from: mid - corner, to: size.height, live: row.laterRunning)
            }
            var elbow = Path()
            elbow.move(to: CGPoint(x: x, y: mid - corner))
            elbow.addQuadCurve(to: CGPoint(x: x + corner, y: mid), control: CGPoint(x: x, y: mid))
            elbow.addLine(to: CGPoint(x: Layout.x(level: row.depth) - 8.5, y: mid))
            Flow.stroke(ctx, elbow, live: row.activity, start: offset + mid - corner, time: time)

            if row.hasChildren {
                line(Layout.x(level: row.depth), from: mid + 8.5, to: size.height, live: row.childRunning)
            }
        }
    }
}

/// A small rounded square with the kind of subagent: a search, a skill, a web fetch, a fork…
private struct TypeChip: View {
    let subagent: Subagent

    private var tint: Color { subagent.running ? Layout.color(subagent.activity) : .secondary }

    var body: some View {
        Image(systemName: subagent.watching ? "terminal" : symbol)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 17, height: 17)
            .background(RoundedRectangle(cornerRadius: 4.5).fill(tint.opacity(subagent.running ? 0.16 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4.5).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
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
