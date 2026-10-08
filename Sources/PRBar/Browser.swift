import AppKit

/// Opens links in the default browser, switching to a tab that already shows the page instead of
/// opening a duplicate. Browsers without tab scripting (Firefox…) always get a new tab, and so does
/// any browser whose script fails, so the worst case is the old behaviour.
enum Browser {
    /// Chromium-based browsers share Chrome's AppleScript dictionary.
    private static let chromium: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary", "com.brave.browser",
        "com.microsoft.edgemac", "com.vivaldi.vivaldi", "org.chromium.chromium",
    ]
    private static let queue = DispatchQueue(label: "prbar.browser")

    /// Like a new tab, this leaves the browser in the background, so the panel stays open,
    /// unless `activate` brings it forward (for a click on a notification, where there's no panel).
    static func open(_ url: URL, activate: Bool = false) {
        queue.async {
            let found = selectExistingTab(url)
            DispatchQueue.main.async {
                if !found {
                    if activate { NSWorkspace.shared.open(url) } else { openInBackground(url) }
                } else if activate, let app = NSWorkspace.shared.urlForApplication(toOpen: url),
                          let id = Bundle(url: app)?.bundleIdentifier {
                    NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
                }
            }
        }
    }

    private static func selectExistingTab(_ url: URL) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              let id = Bundle(url: app)?.bundleIdentifier,
              // Asking a browser that isn't running would launch it.
              !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
              let select = selectStatements(for: id)
        else { return false }

        // The URL goes in as an argument, so it needs no escaping. AppleScript compares text
        // case-insensitively, which suits GitHub's owner and repo names.
        let script = """
        on run argv
            set target to item 1 of argv
            tell application id "\(id)"
                repeat with w in windows
                    try
                        set urls to URL of tabs of w
                        repeat with i from 1 to count of urls
                            if my samePage(item i of urls, target) then
                                \(select)
                                try
                                    set index of w to 1
                                end try
                                return "found"
                            end if
                        end repeat
                    end try
                end repeat
            end tell
            return "none"
        end run

        -- The page itself or a subpage of it, like a PR's /files or #discussion link.
        on samePage(u, target)
            if u is missing value then return false
            set u to u as text
            if u is target then return true
            repeat with sep in {"/", "?", "#"}
                if u starts with (target & sep) then return true
            end repeat
            return false
        end samePage
        """
        // The first run asks for Automation permission; if it's refused, fall back to a new tab.
        guard let out = try? Shell.run(["osascript", "-e", script, url.absoluteString], timeout: 60) else { return false }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "found"
    }

    private static func selectStatements(for bundleID: String) -> String? {
        if chromium.contains(bundleID.lowercased()) { return "set active tab index of w to i" }
        switch bundleID.lowercased() {
        case "com.apple.safari": return "set current tab of w to tab i of w"
        // Arc lists the tabs of the window's current space; tabs in other spaces get a new tab.
        case "company.thebrowser.browser": return "tell tab i of w to select"
        default: return nil
        }
    }
}
