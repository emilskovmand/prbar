import AppKit
import CoreServices

/// Spotlight doesn't index Homebrew's folders, so a Homebrew install adds a small launcher app at
/// ~/Applications/PRBar.app. Opening it starts PRBar under `brew services`, or shows the panel if it's running.
enum Launcher {
    static let bundleID = "dk.blissbudget.prbar.launcher"
    /// Bump when the script, plist or icon changes, so existing launchers get rewritten.
    static let version = "1"
    /// Set by the launcher before it starts PRBar, so the panel opens once it's up.
    static let showPanelKey = "showPanelOnLaunch"
    static let showPanelNotification = Notification.Name("dk.blissbudget.prbar.showPanel")

    private static let destination = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/PRBar.app")

    static func install() {
        guard isHomebrewInstall else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            let info = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
            switch info?["CFBundleIdentifier"] as? String {
            case bundleID where info?["PRBarLauncherVersion"] as? String == version:
                return
            case bundleID:
                try? fm.removeItem(at: destination)
            case Bundle.main.bundleIdentifier:
                // A full copy from a source build: opening it from Spotlight would run that old version
                // next to the Homebrew one. Trash rather than delete, in case it was wanted.
                do { try fm.trashItem(at: destination, resultingItemURL: nil) } catch { return }
            default:
                return  // something else of the user's
            }
        }
        do {
            try write()
            LSRegisterURL(destination as CFURL, true)
        } catch {
            NSLog("PRBar: couldn't add the Spotlight launcher: \(error)")
        }
    }

    private static func write() throws {
        let macOS = destination.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleName": "PRBar",
            "CFBundleDisplayName": "PRBar",
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "LSUIElement": true,
            "PRBarLauncherVersion": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: destination.appendingPathComponent("Contents/Info.plist"))

        let script = destination.appendingPathComponent("Contents/MacOS/launch")
        try """
        #!/bin/sh
        # Written by PRBar. Spotlight doesn't index Homebrew's folders, so this opens the Homebrew copy.
        APP='\(stableAppPath)'
        SERVICE="gui/$(id -u)/sh.brew.prbar"
        [ -d "$APP" ] || exit 1
        if pgrep -qxu "$(id -u)" PRBar; then
          exec "$APP/Contents/MacOS/PRBar" --show-panel   # already running: show its panel
        fi
        defaults write \(Bundle.main.bundleIdentifier ?? "dk.blissbudget.prbar") \(showPanelKey) -bool true
        if launchctl print "$SERVICE" >/dev/null 2>&1; then
          launchctl kickstart "$SERVICE"   # start it as the brew service, like at login
        else
          open "$APP"
        fi

        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        NSWorkspace.shared.setIcon(icon(), forFile: destination.path, options: [])
    }

    /// The menu bar's pull request symbol on a rounded square, so the launcher doesn't show a blank app icon.
    private static func icon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            // macOS icons leave a margin around the rounded square.
            let square = rect.insetBy(dx: 50, dy: 50)
            let path = NSBezierPath(roundedRect: square, xRadius: 92, yRadius: 92)
            NSGradient(starting: NSColor(red: 0.20, green: 0.27, blue: 0.36, alpha: 1),
                       ending: NSColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1))?.draw(in: path, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: 220, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(red: 0.25, green: 0.80, blue: 0.45, alpha: 1)]))
            if let symbol = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}
