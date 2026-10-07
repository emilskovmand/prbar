import AppKit

/// Checks GitHub for a newer release tag and, for Homebrew installs, upgrades and restarts PRBar.
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case updating
        case failed(String)
    }

    @Published private(set) var latest: String?
    @Published private(set) var state: State = .idle

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    /// A newer release than the one running, if any. Dev builds ("0.1.4-3-gabc") compare by their base version.
    var available: String? {
        guard let latest, let a = Version(latest), let b = Version(current), a > b else { return nil }
        return latest
    }

    private var timer: Timer?
    private let tagsURL = URL(string: "https://api.github.com/repos/emilskovmand/prbar/tags?per_page=100")!

    func start() {
        check()
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check() {
        var req = URLRequest(url: tagsURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let tags = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let newest = tags
                .compactMap { $0["name"] as? String }
                .compactMap { name in Version(name).map { (name, $0) } }
                .max { $0.1 < $1.1 }
            DispatchQueue.main.async { self?.latest = newest.map { String($0.0.drop { $0 == "v" }) } }
        }.resume()
    }

    /// Homebrew installs upgrade in place; other builds get the release page.
    func update() {
        guard isHomebrewInstall else {
            NSWorkspace.shared.open(URL(string: "https://github.com/emilskovmand/prbar#install")!)
            return
        }
        state = .updating
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // `brew upgrade` only auto-refreshes taps once a day, so fetch the new formula first.
                _ = try Shell.run(["brew", "update", "--quiet"], timeout: 300)
                _ = try Shell.run(["brew", "upgrade", "emilskovmand/tap/prbar"], timeout: 900)
                DispatchQueue.main.async { Self.restart() }
            } catch {
                DispatchQueue.main.async { self?.state = .failed("\(error)") }
            }
        }
    }

    /// Relaunches the newly installed version. Under `brew services`, launchd restarts the job;
    /// otherwise a new instance is opened before this one quits.
    private static func restart() {
        let label = "sh.brew.prbar"
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label {
            _ = try? Shell.run(["launchctl", "kickstart", "-k", "gui/\(getuid())/\(label)"], timeout: 10)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let app = URL(fileURLWithPath: stableAppPath)
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// A "1.2.3" version, ignoring a leading "v" and any "-suffix".
struct Version: Comparable {
    let parts: [Int]

    init?(_ string: String) {
        let core = string.drop { $0 == "v" }.split(separator: "-").first.map(String.init) ?? ""
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}
