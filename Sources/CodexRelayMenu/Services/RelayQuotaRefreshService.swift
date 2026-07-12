import Foundation
import Darwin

enum RelayQuotaRefreshServiceError: LocalizedError {
    case helperUnavailable
    case timedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "找不到 codex-relay helper"
        case .timedOut:
            return "官方额度刷新超时"
        case .commandFailed(let message):
            return message.isEmpty ? "官方额度刷新失败" : message
        }
    }
}

final class RelayQuotaRefreshProcessRegistry: @unchecked Sendable {
    static let shared = RelayQuotaRefreshProcessRegistry()

    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    private init() {}

    @discardableResult
    func register(_ process: Process) -> Bool {
        lock.lock()
        let shouldStop = stopped
        if !shouldStop { self.process = process }
        lock.unlock()
        if shouldStop { terminateProcessTree(process) }
        return !shouldStop
    }

    func unregister(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let active = process
        process = nil
        lock.unlock()
        guard let active, active.isRunning else { return }
        terminateProcessTree(active)
    }
}

struct RelayQuotaRefreshService {
    static func refresh(profileCount: Int) async throws {
        guard let helperPath = RelaySupervisor.shared.helperPath() else {
            throw RelayQuotaRefreshServiceError.helperUnavailable
        }
        try Task.checkCancellation()

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["refresh"]
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        guard RelayQuotaRefreshProcessRegistry.shared.register(process) else {
            throw CancellationError()
        }
        defer { RelayQuotaRefreshProcessRegistry.shared.unregister(process) }

        let outputTask = Task.detached {
            output.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached {
            errors.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            let timeout = Date().addingTimeInterval(timeoutSeconds(profileCount: profileCount))
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < timeout else { throw RelayQuotaRefreshServiceError.timedOut }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            terminateProcessTree(process)
            _ = await outputTask.value
            _ = await errorTask.value
            throw error
        }

        process.waitUntilExit()
        let outputData = await outputTask.value
        let errorData = await errorTask.value
        guard process.terminationStatus == 0 else {
            let errorText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outputText = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RelayQuotaRefreshServiceError.commandFailed(
                compactMessage(errorText.isEmpty ? outputText : errorText)
            )
        }
    }

    static func timeoutSeconds(profileCount: Int) -> TimeInterval {
        Double(max(1, profileCount) + 1) * 75
    }

    private static func compactMessage(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).last.map(String.init) ?? message
        let cleaned = line.replacingOccurrences(of: "codex-relay: ", with: "")
        return String(cleaned.prefix(160))
    }
}

private func terminateProcessTree(_ process: Process) {
    guard process.isRunning else { return }
    let descendants = relayRefreshDescendantPIDs(of: process.processIdentifier)
    descendants.reversed().forEach { Darwin.kill($0, SIGTERM) }
    process.terminate()
    let deadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < deadline {
        Darwin.usleep(50_000)
    }
    descendants.reversed().forEach { Darwin.kill($0, SIGKILL) }
    if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

private func relayRefreshDescendantPIDs(of parentPID: pid_t) -> [pid_t] {
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
    return children + children.flatMap { relayRefreshDescendantPIDs(of: $0) }
}
