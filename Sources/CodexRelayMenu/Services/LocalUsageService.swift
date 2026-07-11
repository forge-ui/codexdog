import Foundation
import Darwin

final class LocalUsageProcessRegistry: @unchecked Sendable {
    static let shared = LocalUsageProcessRegistry()

    private let lock = NSLock()
    private var process: Process?

    private init() {}

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let active = process
        process = nil
        lock.unlock()
        guard let active, active.isRunning else { return }
        active.terminate()
        let deadline = Date().addingTimeInterval(1)
        while active.isRunning, Date() < deadline {
            Darwin.usleep(50_000)
        }
        if active.isRunning { Darwin.kill(active.processIdentifier, SIGKILL) }
        active.waitUntilExit()
    }
}

enum LocalUsageServiceError: LocalizedError {
    case scannerUnavailable
    case scannerFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .scannerUnavailable:
            return "未找到本机用量扫描器"
        case .scannerFailed(let message):
            return message.isEmpty ? "本机用量扫描失败" : message
        case .emptyResult:
            return "没有读取到本机用量"
        }
    }
}

struct LocalUsageService {
    static func fetch() async throws -> LocalUsageSnapshot {
        guard let executable = executableURL() else {
            throw LocalUsageServiceError.scannerUnavailable
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["cost", "--provider", "codex", "--format", "json"]
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        LocalUsageProcessRegistry.shared.register(process)
        defer { LocalUsageProcessRegistry.shared.unregister(process) }
        let outputTask = Task.detached {
            output.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached {
            errors.fileHandleForReading.readDataToEndOfFile()
        }
        do {
            let timeout = Date().addingTimeInterval(120)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < timeout else {
                    throw LocalUsageServiceError.scannerFailed("本机用量扫描超时")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            terminate(process)
            _ = await outputTask.value
            _ = await errorTask.value
            throw error
        }
        process.waitUntilExit()
        let data = await outputTask.value
        let errorData = await errorTask.value

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LocalUsageServiceError.scannerFailed(message)
        }

        let results = try JSONDecoder().decode([LocalUsageSnapshot].self, from: data)
        guard let snapshot = results.first(where: { $0.provider == "codex" }) else {
            throw LocalUsageServiceError.emptyResult
        }
        return snapshot
    }

    private static func terminate(_ process: Process) {
        LocalUsageProcessRegistry.shared.stop()
    }

    private static func executableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/codexbar",
            "/usr/local/bin/codexbar",
            "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}
