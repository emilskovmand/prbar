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
    let view = NSHostingView(rootView: PanelView(store: delegate.store).background(Color(nsColor: .windowBackgroundColor)))
    view.frame.size = view.fittingSize
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))  // let the content height settle
    view.frame.size = view.fittingSize
    view.layoutSubtreeIfNeeded()
    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
