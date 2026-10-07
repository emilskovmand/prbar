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

    /// Same symbols and colors as the panel, counting exactly what the panel lists.
    private func renderTitle() {
        let c = store.counts
        let title = NSMutableAttributedString()
        func add(_ indicator: Indicator, _ count: Int, _ label: String, into tips: inout [String]) {
            guard count > 0 else { return }
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                .applying(.init(paletteColors: [indicator.nsColor]))
            if let image = NSImage(systemSymbolName: indicator.symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(config) {
                image.isTemplate = false
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -1.5, width: image.size.width, height: image.size.height)
                title.append(NSAttributedString(string: title.length > 0 ? "  " : " "))
                title.append(NSAttributedString(attachment: attachment))
            }
            title.append(NSAttributedString(string: "\u{2009}\(count)", attributes: [.font: barFont]))
            tips.append("\(count) \(label)")
        }
        var tips: [String] = []
        add(.needsYou, c.needsYou, c.needsYou == 1 ? "agent needs you" : "agents need you", into: &tips)
        add(.working, c.working, c.working == 1 ? "agent working" : "agents working", into: &tips)
        add(.failing, c.failing, c.failing == 1 ? "PR failing CI" : "PRs failing CI", into: &tips)
        add(.changesRequested, c.changesRequested, c.changesRequested == 1 ? "PR with changes requested" : "PRs with changes requested", into: &tips)
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = tips.isEmpty ? "PRBar" : tips.joined(separator: "\n")
    }

    private let barFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
}
