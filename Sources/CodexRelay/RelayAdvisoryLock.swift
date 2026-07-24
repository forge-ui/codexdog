import Foundation
import Darwin

enum RelayAdvisoryLockError: LocalizedError {
    case systemCall(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .systemCall(let operation, let path, let code):
            return "Could not \(operation) advisory lock at \(path): \(String(cString: strerror(code)))"
        }
    }
}

final class RelayAdvisoryLockLease {
    private let guardLock = NSLock()
    private var descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        guardLock.lock()
        let descriptorToClose = descriptor
        descriptor = -1
        guardLock.unlock()

        guard descriptorToClose >= 0 else { return }
        _ = flock(descriptorToClose, LOCK_UN)
        _ = Darwin.close(descriptorToClose)
    }

    deinit {
        release()
    }
}

struct RelayAdvisoryLock {
    let fileURL: URL

    init(root: URL) {
        fileURL = root.appendingPathComponent("operation.lock", isDirectory: false)
    }

    func acquire() throws -> RelayAdvisoryLockLease {
        guard let lease = try acquire(nonBlocking: false) else {
            preconditionFailure("A blocking advisory lock unexpectedly returned without a lease")
        }
        return lease
    }

    func tryAcquire() throws -> RelayAdvisoryLockLease? {
        try acquire(nonBlocking: true)
    }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        let lease = try acquire()
        defer { lease.release() }
        return try operation()
    }

    private func acquire(nonBlocking: Bool) throws -> RelayAdvisoryLockLease? {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw RelayAdvisoryLockError.systemCall(
                operation: "open", path: fileURL.path, code: errno)
        }

        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw RelayAdvisoryLockError.systemCall(
                operation: "secure", path: fileURL.path, code: code)
        }

        let operation = LOCK_EX | (nonBlocking ? LOCK_NB : 0)
        while flock(descriptor, operation) != 0 {
            let code = errno
            if code == EINTR { continue }
            if nonBlocking && (code == EWOULDBLOCK || code == EAGAIN) {
                _ = Darwin.close(descriptor)
                return nil
            }
            _ = Darwin.close(descriptor)
            throw RelayAdvisoryLockError.systemCall(
                operation: "acquire", path: fileURL.path, code: code)
        }
        return RelayAdvisoryLockLease(descriptor: descriptor)
    }
}

extension RelayEngine {
    func runWithAdvisoryLock(_ advisoryLock: RelayAdvisoryLock, parentPID: pid_t? = nil) throws -> Never {
        if let parentPID { monitorAdvisoryRunParent(parentPID) }
        while true {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            do {
                let result = try advisoryLock.withLock {
                    do {
                        return try checkOnce(respectingSchedule: true)
                    } catch {
                        if var state = try? storage.loadState() {
                            state.lastError = error.localizedDescription
                            try? storage.saveState(state)
                            try? storage.saveRuntime(RelayRuntimeStatus(
                                updatedAt: Date(), activeProfile: state.activeProfile,
                                primaryUsedPercent: nil, secondaryUsedPercent: nil,
                                planType: nil, message: "ERROR \(error.localizedDescription)"
                            ))
                        }
                        throw error
                    }
                }
                writeAdvisoryRunLog("[\(timestamp)] \(result)")
            } catch {
                writeAdvisoryRunLog("[\(timestamp)] ERROR \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: Double(config.pollIntervalSeconds))
        }
    }

    private func writeAdvisoryRunLog(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private func monitorAdvisoryRunParent(_ parentPID: pid_t) {
        Thread.detachNewThread {
            while Darwin.kill(parentPID, 0) == 0 || errno == EPERM {
                Thread.sleep(forTimeInterval: 1)
            }
            self.advisoryRunDescendants(of: Darwin.getpid()).reversed().forEach {
                Darwin.kill($0, SIGKILL)
            }
            let group = Darwin.getpgrp()
            if group == Darwin.getpid() {
                _ = Darwin.kill(-group, SIGTERM)
            }
            Darwin._exit(0)
        }
    }

    private func advisoryRunDescendants(of parentPID: pid_t) -> [pid_t] {
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
        return children + children.flatMap { advisoryRunDescendants(of: $0) }
    }
}
