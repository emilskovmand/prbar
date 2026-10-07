import Foundation

enum Shell {
    /// Menu bar apps launch with a minimal PATH, so add the usual tool locations.
    static let path: String = {
        let home = NSHomeDirectory()
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (extra + [inherited]).joined(separator: ":")
    }()

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ args: [String], cwd: String? = nil, timeout: TimeInterval = 30) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()

        // Read before waiting so a large output cannot fill the pipe and deadlock.
        var data = Data()
        let reader = DispatchQueue(label: "shell-read")
        let group = DispatchGroup()
        group.enter()
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw Failure(description: "\(args.first ?? "") timed out")
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure(description: msg.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? "exit \(p.terminationStatus)")
        }
        return data
    }
}
