import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let updater = Updater()
    let focus = FocusTracker()
    private lazy var notifier = Notifier(store: store)
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel = FloatingPanel(rootView: PanelView(store: store, updater: updater, focus: focus))

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Pull requests")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
        }

        store.onChange = { [weak self] in
            self?.renderTitle()
            self?.notifier.update()
        }
        notifier.start()
        store.start()
        updater.start()
        focus.panelVisible = { [weak self] in self?.panel.isVisible ?? false }
        focus.start()
        renderTitle()

        DispatchQueue.global(qos: .utility).async { Launcher.install() }
        // Opening the launcher while PRBar runs sends this (see `--show-panel`).
        DistributedNotificationCenter.default().addObserver(forName: Launcher.showPanelNotification, object: nil, queue: .main) { [weak self] _ in
            self?.showPanel()
        }
        // Started from the Spotlight launcher: show the panel once the menu bar item has its place.
        if UserDefaults.standard.bool(forKey: Launcher.showPanelKey) {
            UserDefaults.standard.removeObject(forKey: Launcher.showPanelKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPanel() }
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.hide() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button, !panel.isVisible else { return }
        panel.show(below: button)
    }

    private func renderTitle() {
        let (title, tip) = Self.title(for: store.counts)
        statusItem.button?.attributedTitle = title
        // The green and grey PR icons already say what this is; keep the plain icon only when there's nothing to count.
        statusItem.button?.image = title.length > 0 ? nil : Self.baseIcon
        statusItem.button?.toolTip = tip
    }

    private static let baseIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Pull requests")
        image?.isTemplate = true
        return image
    }()

    /// PR counts use the same icons as the PR rows in the panel; agents only show up here when one needs you.
    static func title(for c: Store.Counts) -> (NSAttributedString, String) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let title = NSMutableAttributedString()
        var tips: [String] = []

        func add(_ indicator: Indicator, _ count: Int, _ one: String, _ many: String, image custom: NSImage? = nil, tip: String? = nil) {
            guard count > 0 else { return }
            // Two palette colors, so the ✗ or pencil inside the circle stays visible like in the panel;
            // with one color the whole symbol fills in and reads as a plain dot.
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: indicator.hasGlyph ? [.white, indicator.nsColor] : [indicator.nsColor]))
            if let image = custom ?? NSImage(systemSymbolName: indicator.symbol, accessibilityDescription: one)?
                .withSymbolConfiguration(config) {
                image.isTemplate = false
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -2.5, width: image.size.width, height: image.size.height)
                title.append(NSAttributedString(string: title.length > 0 ? "   " : " "))
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: " \(count)", attributes: [.font: font]))
            tips.append(tip ?? "\(count) \(count == 1 ? one : many)")
        }
        add(.needsYou, c.needsYou, "agent needs you", "agents need you")
        let running = c.agentsRunning + c.subagentsRunning
        add(.working, running, "agent running", "agents running", image: robotIcon(),
            tip: [c.agentsRunning > 0 ? "\(c.agentsRunning) agent\(c.agentsRunning == 1 ? "" : "s")" : nil,
                  c.subagentsRunning > 0 ? "\(c.subagentsRunning) subagent\(c.subagentsRunning == 1 ? "" : "s")" : nil]
                .compactMap { $0 }.joined(separator: " and ") + " running")
        add(.ready, c.ready, "PR ready for review", "PRs ready for review")
        add(.draft, c.drafts, "draft PR", "draft PRs")
        add(.failing, c.failing, "PR failing CI or with conflicts", "PRs failing CI or with conflicts")
        return (title, tips.isEmpty ? "PRBar" : tips.joined(separator: "\n"))
    }
}

/// A small robot head for the menu bar's running-agents count, drawn to match the adjacent symbols.
func robotIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 15, height: 15), flipped: true) { _ in
        let shape = NSBezierPath()
        shape.appendRoundedRect(NSRect(x: 6.8, y: 1.9, width: 1.4, height: 3.4), xRadius: 0.7, yRadius: 0.7)
        shape.appendRoundedRect(NSRect(x: 2.5, y: 3.6, width: 10, height: 9.4), xRadius: 1.8, yRadius: 1.8)
        shape.appendRoundedRect(NSRect(x: 0.5, y: 6.4, width: 1.5, height: 4.4), xRadius: 0.7, yRadius: 0.7)
        shape.appendRoundedRect(NSRect(x: 13, y: 6.4, width: 1.5, height: 4.4), xRadius: 0.7, yRadius: 0.7)

        // Reverse the eye paths to cut them out of the filled head.
        shape.append(NSBezierPath(ovalIn: NSRect(x: 4.45, y: 7, width: 2.1, height: 2.1)).reversed)
        shape.append(NSBezierPath(ovalIn: NSRect(x: 8.45, y: 7, width: 2.1, height: 2.1)).reversed)

        let blue = NSColor(srgbRed: 0.27, green: 0.59, blue: 0.88, alpha: 1)
        let violet = NSColor(srgbRed: 0.56, green: 0.35, blue: 0.84, alpha: 1)
        NSGradient(starting: blue, ending: violet)?.draw(in: shape, angle: 35)
        return true
    }
    image.accessibilityDescription = "Agents running"
    return image
}
