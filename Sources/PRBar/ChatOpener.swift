import AppKit

/// Opens an agent's chat where it lives: the iTerm/Terminal tab of a running CLI session, a new
/// terminal window or Claude Desktop for a finished one (wherever it was started), Codex, or claude.ai.
enum ChatOpener {

    /// Where `open` will take the user, for tooltips.
    static func destination(for agent: Agent) -> String {
        switch agent.kind {
        case .codex: return "Opens in Codex"
        case .cloud: return "Opens on claude.ai"
        case .local:
            if agent.running { return agent.hostApp?.lastPathComponent == "Claude.app" ? "Opens in Claude Desktop" : "Switches to its terminal tab" }
            return agent.source == "Desktop" ? "Opens in Claude Desktop" : "Resumes in a new terminal window"
        }
    }

    static func open(_ agent: Agent) {
        switch agent.kind {
        case .codex, .cloud:
            if let url = agent.openURL { NSWorkspace.shared.open(url) }
        case .local:
            if agent.running {
                focusRunning(agent)
            } else if agent.source == "Desktop" {
                // Started in Claude Desktop, so that's where this user works.
                openInDesktop(agent)
            } else {
                resumeInTerminal(agent)
            }
        }
    }

    // MARK: Running sessions

    private static func focusRunning(_ agent: Agent) {
        let app = agent.hostApp?.lastPathComponent
        if let tty = agent.tty, app == "iTerm.app", runAppleScript(iTermSelect(tty: tty)) { return }
        if let tty = agent.tty, app == "Terminal.app", runAppleScript(terminalSelect(tty: tty)) { return }
        if app == "Claude.app" { openInDesktop(agent); return }
        // Anything else (Cursor, VS Code, Ghostty…): bring the app forward.
        if let host = agent.hostApp { NSWorkspace.shared.open(host) }
    }

    private static func iTermSelect(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escape(tty))" then
                            select w
                            select t
                            select s
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    private static func terminalSelect(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escape(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    // MARK: Ended sessions

    /// Claude Desktop imports the CLI transcript and opens it in its Code tab.
    private static func openInDesktop(_ agent: Agent) {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "session", value: agent.id)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private static func resumeInTerminal(_ agent: Agent) {
        guard let cmd = agent.resumeCommand else { return }
        let iTermInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
        let script = iTermInstalled
            ? """
              tell application "iTerm2"
                  activate
                  set w to (create window with default profile)
                  tell current session of w to write text "\(escape(cmd))"
              end tell
              return true
              """
            : """
              tell application "Terminal"
                  activate
                  do script "\(escape(cmd))"
              end tell
              return true
              """
        _ = runAppleScript(script)
    }

    // MARK: AppleScript

    /// Returns whether the script ran and returned true. The first run asks for Automation permission.
    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("PRBar: AppleScript failed: \(error)") }
        return result?.booleanValue ?? false
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
