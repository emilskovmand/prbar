import AppKit

/// Which chat you're looking at: the tty of the current tab in iTerm2 or Terminal, matched against
/// the tty of each running Claude Code session. Other apps can't tell which chat is open, so
/// switching to one clears it.
final class FocusTracker: ObservableObject {
    /// The tty of the terminal tab in front (e.g. /dev/ttys002), or nil when another app is.
    @Published private(set) var tty: String?

    /// Terminals are only asked while the panel shows, so nothing runs while it's closed.
    var panelVisible: () -> Bool = { false }

    private static let scripts = [
        "com.googlecode.iterm2": """
            tell application id "com.googlecode.iterm2"
                with timeout of 2 seconds
                    return tty of current session of current window
                end timeout
            end tell
            """,
        "com.apple.Terminal": """
            tell application id "com.apple.Terminal"
                with timeout of 2 seconds
                    return tty of selected tab of front window
                end timeout
            end tell
            """,
    ]

    private let queue = DispatchQueue(label: "prbar.focus")
    private var compiled: [String: NSAppleScript] = [:]   // only touched on `queue`
    /// The bundle id of the terminal that was last in front, if the last app in front was one.
    private var terminal: String?
    /// Bumped whenever another app comes forward, so a slow answer about the previous one is dropped.
    private var generation = 0
    private var timer: Timer?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            self?.activated(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        activated(NSWorkspace.shared.frontmostApplication)
        // Follows tab switches while Keep Panel on Top leaves the panel over the terminal.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let terminal = self.terminal, self.panelVisible(),
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminal else { return }
            self.check(terminal)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func isFocused(_ agent: Agent) -> Bool {
        agent.tty != nil && agent.tty == tty
    }

    private func activated(_ app: NSRunningApplication?) {
        generation += 1
        if app?.processIdentifier == NSRunningApplication.current.processIdentifier {
            // Opening the panel brings PRBar forward; the terminal behind it still knows which tab you left.
            if let terminal { check(terminal) }
        } else if let id = app?.bundleIdentifier, Self.scripts[id] != nil {
            terminal = id
            if panelVisible() { check(id) }
        } else {
            terminal = nil
            tty = nil
        }
    }

    private func check(_ id: String) {
        let generation = generation
        queue.async { [weak self] in
            guard let self else { return }
            let tty = self.currentTTY(in: id)
            DispatchQueue.main.async {
                guard generation == self.generation, tty != self.tty else { return }
                self.tty = tty
            }
        }
    }

    /// Only asks a terminal PRBar may already control: the Chat button asks for that permission
    /// when you click it, and a dialog popping up here would come out of nowhere.
    private func currentTTY(in id: String) -> String? {
        let target = NSAppleEventDescriptor(bundleIdentifier: id)
        guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr,
              let source = Self.scripts[id] else { return nil }
        if compiled[id] == nil { compiled[id] = NSAppleScript(source: source) }
        var error: NSDictionary?
        // Fails without an open window, which leaves no tab in focus.
        let tty = compiled[id]?.executeAndReturnError(&error).stringValue
        return tty?.isEmpty == false ? tty : nil
    }
}
