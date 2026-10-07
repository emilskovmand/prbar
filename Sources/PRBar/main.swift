import AppKit
import SwiftUI

let app = NSApplication.shared
let delegate = AppDelegate()

if CommandLine.arguments.contains("--show-panel") {
    // From the Spotlight launcher when PRBar is already running: ask that copy to show its panel.
    DistributedNotificationCenter.default().postNotificationName(Launcher.showPanelNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    delegate.store.dump()
    exit(0)
}

/// Renders the panel to a PNG at 2x, the way it looks in `appearance`.
func renderPanel(to path: String, appearance: NSAppearance.Name? = nil, rounded: Bool = false, settle: TimeInterval) throws {
    let panel = PanelView(store: delegate.store, updater: delegate.updater)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: rounded ? 12 : 0, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: rounded ? 12 : 0, style: .continuous).strokeBorder(Color.primary.opacity(rounded ? 0.15 : 0)))
    let view = NSHostingView(rootView: panel)
    if let appearance { view.appearance = NSAppearance(named: appearance) }
    view.frame.size = view.fittingSize
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))  // let async work and the content height settle
    view.frame.size = view.fittingSize
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

if let i = CommandLine.arguments.firstIndex(of: "--demo-screenshots"), i + 1 < CommandLine.arguments.count {
    // `PRBar --demo-screenshots docs`: the README images, both tabs in dark and light, from made-up data.
    let dir = CommandLine.arguments[i + 1]
    let defaults = UserDefaults.standard
    let saved = (defaults.string(forKey: "tab"), defaults.string(forKey: "collapsedSections"))
    defaults.removeObject(forKey: "collapsedSections")
    delegate.store.loadDemo()
    for tab in ["mine", "review"] {
        defaults.set(tab, forKey: "tab")
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            try renderPanel(to: "\(dir)/panel-\(tab)-\(name).png", appearance: appearance, rounded: true, settle: 0.5)
        }
    }
    defaults.set(saved.0, forKey: "tab")
    defaults.set(saved.1, forKey: "collapsedSections")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    // Render the panel to a PNG, for checking the layout without clicking the menu bar.
    delegate.store.loadOnce()
    delegate.updater.check()
    try renderPanel(to: CommandLine.arguments[i + 1], settle: 3)

    // The menu bar title too, on a dark strip like the menu bar.
    let (title, _) = AppDelegate.title(for: delegate.store.counts)
    let size = NSSize(width: title.size().width + 20, height: 24)
    let bar = NSImage(size: size, flipped: false) { rect in
        NSColor(white: 0.12, alpha: 1).setFill()
        rect.fill()
        let m = NSMutableAttributedString(attributedString: title)
        m.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: m.length))
        m.draw(at: NSPoint(x: 10, y: (rect.height - title.size().height) / 2))
        return true
    }
    if let tiff = bar.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1].replacingOccurrences(of: ".png", with: "-bar.png")))
    }
    exit(0)
}

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
