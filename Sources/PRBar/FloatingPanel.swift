import AppKit
import SwiftUI

/// UserDefaults key for the gear menu's "Keep Panel on Top": the panel then stays open when you
/// click another app, until you close it from the menu bar icon or with Esc.
let keepPanelOpenKey = "keepPanelOpen"

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
        // Dragged by its header: keep the new spot, so resizing grows down from there.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.topLeft = NSPoint(x: self.frame.minX, y: self.frame.maxY)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard !Self.keepOpen else { return }
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
            guard !Self.keepOpen else { return }
            self?.hide()
        }
    }

    private static var keepOpen: Bool { UserDefaults.standard.bool(forKey: keepPanelOpenKey) }

    func hide() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        orderOut(nil)
    }
}

/// Put behind a view to drag the panel by it. Buttons on top of it keep their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        // The panel never activates PRBar, so the first click has to start the drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.set()
            window?.performDrag(with: event)
            NSCursor.openHand.set()
        }

        // A tracking area rather than cursor rects: those only apply while PRBar is the active app,
        // which it usually isn't while the panel is open.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { updateCursor(event) }
        override func mouseMoved(with event: NSEvent) { updateCursor(event) }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        /// An open hand where a press would drag; the arrow over buttons drawn on top, like Mine / Review.
        private func updateCursor(_ event: NSEvent) {
            let hit = window?.contentView?.hitTest(event.locationInWindow)
            (hit === self ? NSCursor.openHand : NSCursor.arrow).set()
        }
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
