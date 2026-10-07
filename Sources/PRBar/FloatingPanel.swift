import AppKit
import SwiftUI

/// A borderless panel placed under the menu bar icon when opened. Unlike NSPopover it is not
/// anchored to the icon, so it stays put when an auto-hiding menu bar slides away.
final class FloatingPanel<Content: View>: NSPanel {
    private var topLeft: NSPoint = .zero
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var sizeObservation: NSKeyValueObservation?

    init(rootView: Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let host = NSHostingController(rootView: rootView
            .background(VisualEffect())
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        )
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host

        // A window doesn't follow its content's size on its own (a popover does), so resize it
        // whenever the content changes, keeping the top edge where it was.
        sizeObservation = host.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] host, _ in
            DispatchQueue.main.async { self?.fit(to: host.preferredContentSize) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        })
    }

    override var canBecomeKey: Bool { true }

    private func fit(to size: NSSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        setContentSize(size)
        if isVisible { setFrameTopLeftPoint(topLeft) }
        invalidateShadow()
    }

    /// Esc closes the panel.
    override func cancelOperation(_ sender: Any?) { hide() }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        if let size = contentViewController?.preferredContentSize { fit(to: size) }
        let width = frame.width

        // Centre under the icon, but stay fully on screen.
        let visible = screen.visibleFrame
        let x = min(max(iconFrame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        topLeft = NSPoint(x: x, y: iconFrame.minY - 6)
        setFrameTopLeftPoint(topLeft)

        NSApp.activate()
        makeKeyAndOrderFront(nil)

        // A click in any other app closes the panel, like a popover.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        orderOut(nil)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
