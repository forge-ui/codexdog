import Foundation

struct LaunchAgentManager {
    let label = "com.local.codex-relay"

    func install(executable: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchDomain = "gui/\(getuid())"
        try? launchctl(["bootout", "\(launchDomain)/\(label)"])
        let binaryDirectory = home.appendingPathComponent("Library/Application Support/CodexRelay/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let installedExecutable = binaryDirectory.appendingPathComponent("codex-relay")
        let source = URL(fileURLWithPath: executable).standardizedFileURL
        let temporary = binaryDirectory.appendingPathComponent(".codex-relay.\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: installedExecutable.path) {
            _ = try FileManager.default.replaceItemAt(installedExecutable, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: installedExecutable)
        }
        let directory = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appendingPathComponent("\(label).plist")
        let content: [String: Any] = [
            "Label": label,
            "ProgramArguments": [installedExecutable.path, "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": "/tmp/codex-relay.out.log",
            "StandardErrorPath": "/tmp/codex-relay.err.log"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        try launchctl(["bootstrap", launchDomain, plist.path])
        return plist
    }

    func uninstall() throws {
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try? launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
    }

    private func launchctl(_ arguments: [String], allowAlreadyLoaded: Bool = false) throws {
        let process = Process(); let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments; process.standardError = error
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "launchctl failed"
            if !(allowAlreadyLoaded && message.localizedCaseInsensitiveContains("already")) { throw RelayError.process(message) }
        }
    }
}
