import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel = FloatingPanel(rootView: PanelView(store: store))

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Pull requests")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
        }

        store.onChange = { [weak self] in self?.renderTitle() }
        store.start()
        renderTitle()
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            panel.hide()
        } else {
            panel.show(below: button)
        }
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

        func add(_ indicator: Indicator, _ count: Int, _ one: String, _ many: String) {
            guard count > 0 else { return }
            // Two palette colors, so the ✗ or pencil inside the circle stays visible like in the panel;
            // with one color the whole symbol fills in and reads as a plain dot.
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: indicator.hasGlyph ? [.white, indicator.nsColor] : [indicator.nsColor]))
            if let image = NSImage(systemSymbolName: indicator.symbol, accessibilityDescription: one)?
                .withSymbolConfiguration(config) {
                image.isTemplate = false
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -2.5, width: image.size.width, height: image.size.height)
                title.append(NSAttributedString(string: title.length > 0 ? "   " : " "))
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: " \(count)", attributes: [.font: font]))
            tips.append("\(count) \(count == 1 ? one : many)")
        }
        add(.needsYou, c.needsYou, "agent needs you", "agents need you")
        add(.ready, c.ready, "PR ready for review", "PRs ready for review")
        add(.draft, c.drafts, "draft PR", "draft PRs")
        add(.failing, c.failing, "PR failing CI", "PRs failing CI")
        return (title, tips.isEmpty ? "PRBar" : tips.joined(separator: "\n"))
    }
}
