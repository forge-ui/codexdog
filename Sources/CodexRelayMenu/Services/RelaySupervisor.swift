import Foundation
import Darwin

final class RelaySupervisor: @unchecked Sendable {
    static let shared = RelaySupervisor()

    private let lock = NSLock()
    private var worker: Process?
    private var logHandle: FileHandle?
    private var starting = false
    private var desiredRunning = false
    private var restartAttempt = 0

    private init() {}

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return worker?.isRunning == true
    }

    func helperPath() -> String? {
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: "codex-relay") { return bundled }
        let sibling = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/codex-relay").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        let stable = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexRelay/bin/codex-relay").path
        if FileManager.default.isExecutableFile(atPath: stable) { return stable }
        let cwd = FileManager.default.currentDirectoryPath
        for relative in [".build/debug/codex-relay", ".build/release/codex-relay"] {
            let candidate = URL(fileURLWithPath: cwd).appendingPathComponent(relative).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    func start() throws {
        lock.lock()
        if !desiredRunning { restartAttempt = 0 }
        desiredRunning = true
        if worker?.isRunning == true || starting {
            lock.unlock()
            return
        }
        starting = true
        lock.unlock()

        try launchWorker()
    }

    private func restartIfDesired() {
        lock.lock()
        guard desiredRunning, worker?.isRunning != true, !starting else {
            lock.unlock()
            return
        }
        starting = true
        lock.unlock()
        do {
            try launchWorker()
        } catch {
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        lock.lock()
        guard desiredRunning else {
            lock.unlock()
            return
        }
        restartAttempt += 1
        let delay = min(pow(2.0, Double(restartAttempt)), 60)
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restartIfDesired()
        }
    }

    private func launchWorker() throws {
        guard let helper = helperPath() else {
            lock.lock()
            starting = false
            lock.unlock()
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "找不到 CodexDog helper"])
        }

        removeLegacyLaunchAgent(helper: helper)

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexRelay/worker.log")
        let handle: FileHandle
        do {
            handle = try Self.prepareLogFile(at: logURL)
        } catch {
            lock.lock()
            starting = false
            lock.unlock()
            throw error
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["run", "--parent-pid", String(getpid())]
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.lock.lock()
            let wasCurrentWorker = self.worker === terminated
            if wasCurrentWorker {
                self.worker = nil
                self.logHandle = nil
            }
            let shouldRestart = wasCurrentWorker && self.desiredRunning
            self.lock.unlock()
            if wasCurrentWorker {
                NotificationCenter.default.post(name: .relayWorkerChanged, object: nil)
            }
            if shouldRestart {
                self.scheduleRestart()
            }
        }

        lock.lock()
        guard desiredRunning else {
            starting = false
            lock.unlock()
            try? handle.close()
            return
        }
        worker = process
        logHandle = handle
        starting = false
        do {
            try process.run()
            lock.unlock()
        } catch {
            if worker === process {
                worker = nil
                logHandle = nil
            }
            lock.unlock()
            try? handle.close()
            throw error
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { [weak self, weak process] in
            guard let self, let process else { return }
            self.lock.lock()
            if self.worker === process, process.isRunning { self.restartAttempt = 0 }
            self.lock.unlock()
        }
        NotificationCenter.default.post(name: .relayWorkerChanged, object: nil)
    }

    static func prepareLogFile(at logURL: URL) throws -> FileHandle {
        let manager = FileManager.default
        let directory = logURL.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !manager.fileExists(atPath: logURL.path) {
            guard manager.createFile(
                atPath: logURL.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logURL.path])
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return handle
    }

    func stop() {
        lock.lock()
        desiredRunning = false
        let process = worker
        worker = nil
        let handle = logHandle
        logHandle = nil
        lock.unlock()

        guard let process else {
            try? handle?.close()
            return
        }
        let descendants = descendantPIDs(of: process.processIdentifier)
        if process.isRunning {
            descendants.reversed().forEach { Darwin.kill($0, SIGTERM) }
            Darwin.kill(-process.processIdentifier, SIGTERM)
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            descendants.reversed().forEach { Darwin.kill($0, SIGKILL) }
            Darwin.kill(-process.processIdentifier, SIGKILL)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try? handle?.close()
        NotificationCenter.default.post(name: .relayWorkerChanged, object: nil)
    }

    private func descendantPIDs(of parentPID: pid_t) -> [pid_t] {
        let query = Process()
        let output = Pipe()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        query.arguments = ["-P", String(parentPID)]
        query.standardOutput = output
        query.standardError = FileHandle.nullDevice
        guard (try? query.run()) != nil else { return [] }
        query.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let children = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) } ?? []
        return children + children.flatMap { descendantPIDs(of: $0) }
    }

    private func removeLegacyLaunchAgent(helper: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["uninstall"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

extension Notification.Name {
    static let relayWorkerChanged = Notification.Name("CodexRelay.workerChanged")
}
