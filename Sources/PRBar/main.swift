import AppKit
import SwiftUI

let app = NSApplication.shared
let delegate = AppDelegate()

if CommandLine.arguments.contains("--dump") {
    delegate.store.dump()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    // Render the panel to a PNG, for checking the layout without clicking the menu bar.
    delegate.store.loadOnce()
    delegate.updater.check()
    let view = NSHostingView(rootView: PanelView(store: delegate.store, updater: delegate.updater).background(Color(nsColor: .windowBackgroundColor)))
    view.frame.size = view.fittingSize
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(3))  // let the update check and content height settle
    view.frame.size = view.fittingSize
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }

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
