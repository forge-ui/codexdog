import Foundation
import Darwin

final class AppServerClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private var nextID = 1
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let errorBufferLock = NSLock()
    private let stopLock = NSLock()
    private var errorTail = Data()
    private var errorCaptureFinished = false
    private var stopped = false
    private var receiveBuffer = Data()
    private var newlineSearchOffset = 0

    init(binaryPath: String, codexHome: URL) throws {
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.appendError(data) }
        }
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        do {
            _ = try request("initialize", params: .object([
                "clientInfo": .object(["name": .string("codex-relay"), "title": .string("CodexRelay"), "version": .string("0.8.2")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            try notify("initialized", params: .object([:]))
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func stop(timeout: TimeInterval = 2) {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        defer { stopLock.unlock() }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        finishErrorCapture()
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForReading.close()
        try? error.fileHandleForWriting.close()
    }

    func request(_ method: String, params: JSONValue = .object([:]), timeoutSeconds: TimeInterval = 30) throws -> JSONValue {
        let id = nextID
        nextID += 1
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        try send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]))
        while process.isRunning {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                stop()
                throw RelayError.process("app-server request timed out: \(method)")
            }
            let waitMilliseconds = max(1, min(Int(remaining * 1_000), 1_000))
            guard let line = try readLine(timeoutMilliseconds: waitMilliseconds), !line.isEmpty else { continue }
            let message = try decoder.decode(JSONValue.self, from: line)
            guard let object = message.object else { continue }
            if object["id"]?.int == id {
                if let rpcError = object["error"]?.object {
                    throw RelayError.rpc(rpcError["message"]?.string ?? "Unknown app-server error")
                }
                return object["result"] ?? .null
            }
        }
        finishErrorCapture()
        let stderr = capturedErrorText()
        throw RelayError.process("app-server exited unexpectedly: \(stderr.prefix(500))")
    }

    func notify(_ method: String, params: JSONValue) throws {
        try send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    func rateLimits() throws -> RateLimitSnapshot {
        let result = try request("account/rateLimits/read")
        guard let snapshot = result.object?["rateLimits"]?.object else { throw RelayError.rpc("Missing rateLimits payload") }
        func window(_ key: String) -> RateLimitWindow? {
            guard let object = snapshot[key]?.object, let used = object["usedPercent"]?.int else { return nil }
            return RateLimitWindow(usedPercent: used, resetsAt: object["resetsAt"]?.int64,
                                   windowDurationMins: object["windowDurationMins"]?.int)
        }
        let limits = RateLimitSnapshot(primary: window("primary"), secondary: window("secondary"),
                                       reachedReason: snapshot["rateLimitReachedType"]?.string,
                                       planType: snapshot["planType"]?.string)
        guard limits.hasOfficialLimitSignal else {
            throw RelayError.rpc("Missing official rate limit windows")
        }
        return limits
    }

    func listThreads(limit: Int) throws -> [ThreadRecord] {
        let result = try request("thread/list", params: .object([
            "limit": .number(Double(limit)), "archived": .bool(false),
            "sortKey": .string("updated_at"), "sortDirection": .string("desc"),
            "modelProviders": .array([]), "useStateDbOnly": .bool(true)
        ]))
        guard let data = result.object?["data"]?.array else {
            throw RelayError.rpc("Missing thread list data")
        }
        return data.compactMap { item in
            guard let object = item.object, let id = object["id"]?.string else { return nil }
            return ThreadRecord(id: id, preview: object["preview"]?.string, cwd: object["cwd"]?.string,
                                updatedAt: object["updatedAt"]?.int64,
                                status: object["status"]?.object?["type"]?.string ?? "unknown")
        }
    }

    func unfinishedThreads(from threads: [ThreadRecord], recentHours: Int, now: Date = Date()) -> [ThreadRecord] {
        let cutoff = Int64(now.addingTimeInterval(TimeInterval(-recentHours * 3600)).timeIntervalSince1970)
        let classificationDeadline = Date().addingTimeInterval(20)
        return threads.filter { thread in
            if thread.status == "active" || thread.status == "systemError" { return true }
            guard (thread.updatedAt ?? 0) >= cutoff else { return false }
            guard classificationDeadline.timeIntervalSinceNow > 0 else { return false }
            let goalTimeout = min(3, classificationDeadline.timeIntervalSinceNow)
            if let result = try? request("thread/goal/get", params: .object(["threadId": .string(thread.id)]), timeoutSeconds: goalTimeout),
               let status = result.object?["goal"]?.object?["status"]?.string,
               ["active", "usageLimited", "budgetLimited"].contains(status) { return true }
            guard classificationDeadline.timeIntervalSinceNow > 0 else { return false }
            let readTimeout = min(3, classificationDeadline.timeIntervalSinceNow)
            if let result = try? request("thread/read", params: .object(["threadId": .string(thread.id), "includeTurns": .bool(true)]), timeoutSeconds: readTimeout),
               let turns = result.object?["thread"]?.object?["turns"]?.array,
               let status = turns.last?.object?["status"]?.string,
               ["interrupted", "failed", "inProgress"].contains(status) { return true }
            return false
        }
    }

    func resumeAndWake(_ entry: RecoveryEntry) throws {
        _ = try request("thread/resume", params: .object(["threadId": .string(entry.threadId)]))
        let message = Self.recoveryMessage(recoveryKey: entry.recoveryKey)
        _ = try request("turn/start", params: .object([
            "threadId": .string(entry.threadId),
            "clientUserMessageId": .string(entry.recoveryKey),
            "approvalsReviewer": .string("auto_review"),
            "input": .array([.object(["type": .string("text"), "text": .string(message), "text_elements": .array([])])])
        ]))
    }

    static func recoveryMessage(recoveryKey: String) -> String {
        "请按原计划继续未完成的任务。\n<!-- codex-relay-recovery:\(recoveryKey) -->"
    }

    func recoveryMarkerStatus(_ entry: RecoveryEntry) throws -> RecoveryMarkerStatus {
        try recoveryMarkerStatus(entry, timeoutSeconds: 30)
    }

    private func recoveryMarkerStatus(
        _ entry: RecoveryEntry, timeoutSeconds: TimeInterval
    ) throws -> RecoveryMarkerStatus {
        let result = try request("thread/read", params: .object([
            "threadId": .string(entry.threadId), "includeTurns": .bool(true)
        ]), timeoutSeconds: timeoutSeconds)
        guard let turns = result.object?["thread"]?.object?["turns"]?.array else {
            throw RelayError.rpc("Missing thread turns while checking recovery marker")
        }
        var foundMatch = false
        var foundInProgress = false
        var foundTerminalFailure = false
        for turn in turns where turn.contains(string: entry.recoveryKey) {
            foundMatch = true
            switch turn.object?["status"]?.string {
            case "completed": return .completed
            case "inProgress", "in_progress": foundInProgress = true
            case "failed", "interrupted", "cancelled", "canceled": foundTerminalFailure = true
            default: break
            }
        }
        if foundInProgress { return .inProgress }
        if foundTerminalFailure { return .terminalFailure }
        return foundMatch ? .unknown : .absent
    }

    func waitForTurns(_ entries: [RecoveryEntry], timeoutSeconds: Int) -> Set<String> {
        var remaining = Dictionary(uniqueKeysWithValues: entries.map { ($0.threadId, $0) })
        var completedThreadIDs: Set<String> = []
        var unresolvedSince: [String: Date] = [:]
        let markerUnresolvedGraceSeconds: TimeInterval = 2
        let unresolvedGraceExpired: (String) -> Bool = { recoveryKey in
            let firstUnresolvedAt = unresolvedSince[recoveryKey] ?? Date()
            unresolvedSince[recoveryKey] = firstUnresolvedAt
            return Date().timeIntervalSince(firstUnresolvedAt) >= markerUnresolvedGraceSeconds
        }
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        let pollMilliseconds = min(5_000, max(100, timeoutSeconds * 200))
        while !remaining.isEmpty, process.isRunning, Date() < deadline {
            for (threadID, entry) in remaining {
                if completedThreadIDs.contains(threadID) {
                    remaining.removeValue(forKey: threadID)
                    continue
                }
                let status: RecoveryMarkerStatus
                do {
                    status = try recoveryMarkerStatus(entry, timeoutSeconds: 5)
                } catch {
                    if unresolvedGraceExpired(entry.recoveryKey) {
                        remaining.removeValue(forKey: threadID)
                    }
                    continue
                }
                switch status {
                case .completed:
                    completedThreadIDs.insert(threadID)
                    remaining.removeValue(forKey: threadID)
                case .terminalFailure:
                    remaining.removeValue(forKey: threadID)
                case .absent, .unknown:
                    if unresolvedGraceExpired(entry.recoveryKey) {
                        remaining.removeValue(forKey: threadID)
                    }
                case .inProgress:
                    unresolvedSince.removeValue(forKey: entry.recoveryKey)
                }
            }
            guard !remaining.isEmpty, process.isRunning, Date() < deadline else { break }
            _ = try? readLine(timeoutMilliseconds: pollMilliseconds)
        }
        return Set(entries.map(\.threadId)).intersection(completedThreadIDs)
    }

    private func send(_ value: JSONValue) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLine(timeoutMilliseconds: Int? = nil) throws -> Data? {
        let deadline = timeoutMilliseconds.map {
            Date().addingTimeInterval(Double($0) / 1_000)
        }
        while process.isRunning {
            if newlineSearchOffset < receiveBuffer.count,
               let newline = receiveBuffer[newlineSearchOffset...].firstIndex(of: 0x0A) {
                let line = Data(receiveBuffer[..<newline])
                receiveBuffer.removeSubrange(...newline)
                newlineSearchOffset = 0
                return line
            }
            newlineSearchOffset = receiveBuffer.count
            if let deadline {
                let remainingMilliseconds = Int(deadline.timeIntervalSinceNow * 1_000)
                guard remainingMilliseconds > 0 else { return nil }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&descriptor, 1, Int32(max(1, remainingMilliseconds)))
                if result == 0 { return nil }
                if result < 0 { throw RelayError.process("poll failed: \(String(cString: strerror(errno)))") }
            }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else {
                if receiveBuffer.isEmpty { return nil }
                defer {
                    receiveBuffer.removeAll(keepingCapacity: true)
                    newlineSearchOffset = 0
                }
                return receiveBuffer
            }
            receiveBuffer.append(contentsOf: bytes.prefix(count))
        }
        return receiveBuffer.isEmpty ? nil : receiveBuffer
    }

    private func appendError(_ data: Data) {
        let maximumBytes = 16_384
        errorBufferLock.lock()
        errorTail.append(data)
        if errorTail.count > maximumBytes {
            errorTail = Data(errorTail.suffix(maximumBytes))
        }
        errorBufferLock.unlock()
    }

    private func finishErrorCapture() {
        errorBufferLock.lock()
        let shouldFinish = !errorCaptureFinished
        errorCaptureFinished = true
        errorBufferLock.unlock()
        guard shouldFinish else { return }

        // The readability handler continuously drains stderr. Do not call
        // readToEnd here: a turn subprocess may inherit the pipe and keep EOF
        // open after app-server itself has stopped.
        error.fileHandleForReading.readabilityHandler = nil
    }

    private func capturedErrorText() -> String {
        errorBufferLock.lock()
        let data = errorTail
        errorBufferLock.unlock()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension JSONValue {
    func contains(string needle: String) -> Bool {
        switch self {
        case .string(let value):
            return value.contains(needle)
        case .array(let values):
            return values.contains { $0.contains(string: needle) }
        case .object(let values):
            return values.values.contains { $0.contains(string: needle) }
        case .number, .bool, .null:
            return false
        }
    }
}
