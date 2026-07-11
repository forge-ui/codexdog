import Foundation
import Testing
@testable import CodexRelay

private final class FakeChatGPTController: ChatGPTControlling {
    var isRunning = true
    var quitCount = 0
    var openCount = 0

    func quit() throws {
        quitCount += 1
        isRunning = false
    }

    func openIfNeeded(path: String) throws {
        guard !isRunning else { return }
        openCount += 1
        isRunning = true
    }
}

private final class FakeRelayBackend: @unchecked Sendable {
    let storage: RelayStorage
    let markerLock = NSLock()
    var limitsByAccount: [String: RateLimitSnapshot]
    var failuresByAccountCall: [String: [Int: RelayError]] = [:]
    var rotatedTokenByAccountCall: [String: [Int: String]] = [:]
    var rateLimitCalls: [String: Int] = [:]
    var recoveryMarkers: [String: RecoveryMarkerStatus] = [:]
    var markerReadFailuresRemaining = 0
    var wakeAttempts: [String] = []
    var throwBeforeRecordingWake = false
    var throwAfterRecordingWake = false
    var waitResultStatus: RecoveryMarkerStatus? = .completed

    init(storage: RelayStorage, limitsByAccount: [String: RateLimitSnapshot]) {
        self.storage = storage
        self.limitsByAccount = limitsByAccount
    }

    func accountID(codexHome: URL) throws -> String {
        let data = try Data(contentsOf: codexHome.appendingPathComponent("auth.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String else {
            throw RelayError.verification("Fake auth is missing account_id")
        }
        return accountID
    }

    func rateLimits(codexHome: URL) throws -> RateLimitSnapshot {
        let account = try accountID(codexHome: codexHome)
        let call = (rateLimitCalls[account] ?? 0) + 1
        rateLimitCalls[account] = call
        if let token = rotatedTokenByAccountCall[account]?[call] {
            try engineTestAuth(accountID: account, token: token)
                .write(to: codexHome.appendingPathComponent("auth.json"), options: .atomic)
        }
        if let failure = failuresByAccountCall[account]?[call] { throw failure }
        guard let limits = limitsByAccount[account] else {
            throw RelayError.rpc("No fake limits for \(account)")
        }
        return limits
    }
}

private final class FakeAppServer: AppServerServing, @unchecked Sendable {
    let codexHome: URL
    let backend: FakeRelayBackend

    init(codexHome: URL, backend: FakeRelayBackend) {
        self.codexHome = codexHome
        self.backend = backend
    }

    func stop(timeout: TimeInterval) {}

    func rateLimits() throws -> RateLimitSnapshot {
        try backend.rateLimits(codexHome: codexHome)
    }

    func listThreads(limit: Int) throws -> [ThreadRecord] {
        [ThreadRecord(id: "unfinished-thread", preview: nil, cwd: "/tmp",
                      updatedAt: Int64(Date().timeIntervalSince1970), status: "active")]
    }

    func unfinishedThreads(from threads: [ThreadRecord], recentHours: Int, now: Date) -> [ThreadRecord] {
        threads
    }

    func recoveryMarkerStatus(_ entry: RecoveryEntry) throws -> RecoveryMarkerStatus {
        if backend.markerReadFailuresRemaining > 0 {
            backend.markerReadFailuresRemaining -= 1
            throw RelayError.rpc("temporary thread/read failure")
        }
        backend.markerLock.lock()
        let status = backend.recoveryMarkers[entry.recoveryKey] ?? .absent
        backend.markerLock.unlock()
        return status
    }

    func resumeAndWake(_ entry: RecoveryEntry) throws {
        backend.wakeAttempts.append(entry.recoveryKey)
        if backend.throwBeforeRecordingWake {
            throw RelayError.process("turn was not accepted")
        }
        backend.markerLock.lock()
        backend.recoveryMarkers[entry.recoveryKey] = .inProgress
        backend.markerLock.unlock()
        if backend.throwAfterRecordingWake {
            throw RelayError.process("response lost after turn was accepted")
        }
    }

    func waitForTurns(_ threadIDs: Set<String>, timeoutSeconds: Int) -> Set<String> {
        backend.markerLock.lock()
        if let resultStatus = backend.waitResultStatus {
            for key in Array(backend.recoveryMarkers.keys)
                where backend.recoveryMarkers[key] == .inProgress {
                backend.recoveryMarkers[key] = resultStatus
            }
        }
        backend.markerLock.unlock()
        return threadIDs
    }
}

private struct EngineHarness {
    let root: URL
    let storage: RelayStorage
    let engine: RelayEngine
    let backend: FakeRelayBackend
    let app: FakeChatGPTController
}

private func makeEngineHarness() throws -> EngineHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let config = RelayConfig(
        profiles: ["a", "b"], thresholdUsedPercent: 99,
        switchCooldownSeconds: 0, recoveryRecentHours: 24,
        maxThreadsToWake: 20, maxConcurrentRecoveryTurns: 3,
        dryRun: false, codexHome: codexHome.path)
    let storage = RelayStorage(paths: RelayPaths(
        config: config, rootOverride: root.appendingPathComponent("relay", isDirectory: true)))
    try storage.bootstrap()

    try engineTestAuth(accountID: "account-a", token: "a-token")
        .write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "a")
    try engineTestAuth(accountID: "account-b", token: "b-token")
        .write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "b")
    _ = try storage.activate(profile: "a")
    var state = try storage.loadState()
    state.activeProfile = "a"
    try storage.saveState(state)

    let backend = FakeRelayBackend(storage: storage, limitsByAccount: [
        "account-a": RateLimitSnapshot(
            primary: .init(usedPercent: 99, resetsAt: nil), secondary: nil,
            reachedReason: nil, planType: "pro"),
        "account-b": RateLimitSnapshot(
            primary: .init(usedPercent: 10, resetsAt: nil), secondary: nil,
            reachedReason: nil, planType: "pro"),
    ])
    let app = FakeChatGPTController()
    let engine = RelayEngine(
        storage: storage, config: config, appController: app,
        appServerFactory: { FakeAppServer(codexHome: $0, backend: backend) })
    return EngineHarness(root: root, storage: storage, engine: engine, backend: backend, app: app)
}

private func finishRecovery(_ harness: EngineHarness) throws {
    for _ in 0..<50 {
        if try harness.storage.loadState().pendingSwitch == nil { return }
        Thread.sleep(forTimeInterval: 0.01)
        _ = try harness.engine.checkOnce()
    }
    Issue.record("Recovery did not finish within the test deadline")
}

@Test func engineCommitsSwitchBeforeFinishingRecovery() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let result = try harness.engine.checkOnce()
    let committedState = try harness.storage.loadState()

    #expect(result.contains("Switched a -> b"))
    #expect(try harness.storage.activeAccountID() == "account-b")
    #expect(committedState.activeProfile == "b")
    #expect(committedState.lastSwitchAt != nil)
    #expect(committedState.pendingSwitch?.phase == .recovering)
    #expect(harness.backend.wakeAttempts.count == 1)
    #expect(harness.app.quitCount == 1)
    #expect(harness.app.openCount == 1)
    try finishRecovery(harness)
    #expect(try harness.storage.loadState().pendingSwitch == nil)
}

@Test func invalidCurrentTokenFailsOverToHealthyStandby() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.failuresByAccountCall["account-a"] = [
        1: .rpc("401 Unauthorized: token_invalidated")
    ]

    _ = try harness.engine.checkOnce()

    #expect(try harness.storage.activeAccountID() == "account-b")
    #expect(try harness.storage.loadState().activeProfile == "b")
}

@Test func rotatedTargetTokenSurvivesTransientValidationFailureAndRetry() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.rotatedTokenByAccountCall["account-b"] = [3: "b-rotated"]
    harness.backend.failuresByAccountCall["account-b"] = [3: .rpc("503 Service Unavailable")]

    #expect(throws: RelayError.self) {
        try harness.engine.checkOnce()
    }
    let interrupted = try harness.storage.loadState()
    #expect(interrupted.pendingSwitch?.phase == .activated)
    #expect(try harness.storage.activeAccountID() == "account-b")
    #expect(engineTestToken(try Data(contentsOf: harness.storage.paths.profileAuth("b"))) == "b-rotated")

    _ = try harness.engine.checkOnce()
    try finishRecovery(harness)
    #expect(try harness.storage.loadState().pendingSwitch == nil)
    #expect(try harness.storage.activeAccountID() == "account-b")
}

@Test func terminalTargetValidationFailureRollsBackAndReopensSource() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.failuresByAccountCall["account-b"] = [
        3: .rpc("401 Unauthorized: token_invalidated")
    ]

    let result = try harness.engine.checkOnce()
    let state = try harness.storage.loadState()

    #expect(result.contains("Rolled back"))
    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(state.activeProfile == "a")
    #expect(state.pendingSwitch == nil)
    #expect(state.lastError?.contains("Target validation failed") == true)
    #expect(harness.app.isRunning)
}

@Test func acceptedRecoveryIsReconciledAfterLostResponseWithoutDuplicateTurn() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.throwAfterRecordingWake = true

    _ = try harness.engine.checkOnce()
    try finishRecovery(harness)
    let state = try harness.storage.loadState()

    #expect(harness.backend.wakeAttempts.count == 1)
    #expect(state.pendingSwitch == nil)
    #expect(state.completedRecoveryKeys.count == 1)
    #expect(state.failedRecoveryKeys?.isEmpty != false)
}

@Test func pendingRecoveryKeepsItsIdentityAcrossAnotherAccountSwitch() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.throwBeforeRecordingWake = true

    _ = try harness.engine.checkOnce()
    let firstState = try harness.storage.loadState()
    let originalKey = try #require(firstState.pendingSwitch?.snapshot.threads.first?.recoveryKey)

    harness.backend.throwBeforeRecordingWake = false
    harness.backend.limitsByAccount["account-a"] = RateLimitSnapshot(
        primary: .init(usedPercent: 10, resetsAt: nil), secondary: nil,
        reachedReason: nil, planType: "pro")
    harness.backend.limitsByAccount["account-b"] = RateLimitSnapshot(
        primary: .init(usedPercent: 99, resetsAt: nil), secondary: nil,
        reachedReason: nil, planType: "pro")

    _ = try harness.engine.checkOnce()
    let secondState = try harness.storage.loadState()

    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(secondState.lastSnapshot?.threads.map(\.recoveryKey) == [originalKey])
    #expect(harness.backend.wakeAttempts == [originalKey, originalKey])
}

@Test func markerReadFailurePausesRecoveryInsteadOfSubmittingASecondTurn() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.markerReadFailuresRemaining = 1

    _ = try harness.engine.checkOnce()
    let paused = try harness.storage.loadState()

    #expect(paused.pendingSwitch?.phase == .recovering)
    #expect(harness.backend.wakeAttempts.isEmpty)

    _ = try harness.engine.checkOnce()
    try finishRecovery(harness)
    #expect(try harness.storage.loadState().pendingSwitch == nil)
    #expect(harness.backend.wakeAttempts.count == 1)
}

@Test func interruptedRecoveryHostLeavesPendingStateAndResubmitsTheTurn() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.waitResultStatus = nil

    _ = try harness.engine.checkOnce()
    Thread.sleep(forTimeInterval: 0.02)
    #expect(try harness.storage.loadState().pendingSwitch?.phase == .recovering)
    #expect(harness.backend.wakeAttempts.count == 1)

    _ = try harness.engine.checkOnce()
    #expect(harness.backend.wakeAttempts.count == 2)
    #expect(try harness.storage.loadState().pendingSwitch?.phase == .recovering)
}

@Test func threeTerminalRecoveryTurnsAreRecordedAsFailedAndStopRetrying() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.waitResultStatus = .terminalFailure

    _ = try harness.engine.checkOnce()
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.01)
        _ = try harness.engine.checkOnce()
        if try harness.storage.loadState().pendingSwitch == nil { break }
    }
    let state = try harness.storage.loadState()

    #expect(state.pendingSwitch == nil)
    #expect(state.failedRecoveryKeys?.count == 1)
    #expect(state.completedRecoveryKeys.isEmpty)
    #expect(harness.backend.wakeAttempts.count == 3)
}

@Test func candidateWithoutOfficialQuotaWindowsIsNeverActivated() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.limitsByAccount["account-b"] = RateLimitSnapshot(
        primary: nil, secondary: nil, reachedReason: nil, planType: "pro")

    #expect(throws: RelayError.self) {
        try harness.engine.checkOnce()
    }
    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(try harness.storage.loadState().pendingSwitch == nil)
}

private func engineTestAuth(accountID: String, token: String) -> Data {
    Data(#"{"tokens":{"account_id":"\#(accountID)","access_token":"\#(token)"}}"#.utf8)
}

private func engineTestToken(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any] else { return nil }
    return tokens["access_token"] as? String
}
