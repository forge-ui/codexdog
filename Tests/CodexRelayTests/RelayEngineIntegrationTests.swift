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
    var recoveryThreads = [
        ThreadRecord(id: "unfinished-thread", preview: nil, cwd: "/tmp",
                     updatedAt: Int64(Date().timeIntervalSince1970), status: "active")
    ]

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
        Array(backend.recoveryThreads.prefix(limit))
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

    func waitForTurns(_ entries: [RecoveryEntry], timeoutSeconds: Int) -> Set<String> {
        backend.markerLock.lock()
        if let resultStatus = backend.waitResultStatus {
            for key in Array(backend.recoveryMarkers.keys)
                where backend.recoveryMarkers[key] == .inProgress {
                backend.recoveryMarkers[key] = resultStatus
            }
        }
        backend.markerLock.unlock()
        return Set(entries.map(\.threadId))
    }
}

private struct EngineHarness {
    let root: URL
    let storage: RelayStorage
    let engine: RelayEngine
    let backend: FakeRelayBackend
    let app: FakeChatGPTController
}

private func makeEngineHarness(
    profiles: [String] = ["a", "b"],
    activeProfile: String = "a",
    activeUsedPercent: Int = 99
) throws -> EngineHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let config = RelayConfig(
        profiles: profiles, thresholdUsedPercent: 99,
        switchCooldownSeconds: 0, recoveryRecentHours: 24,
        maxThreadsToWake: 20, maxConcurrentRecoveryTurns: 3,
        dryRun: false, codexHome: codexHome.path)
    let storage = RelayStorage(paths: RelayPaths(
        config: config, rootOverride: root.appendingPathComponent("relay", isDirectory: true)))
    try storage.bootstrap()
    try storage.saveConfig(config)

    for profile in profiles {
        try engineTestAuth(accountID: "account-\(profile)", token: "\(profile)-token")
            .write(to: storage.paths.activeAuth)
        try storage.saveCurrentAuth(as: profile)
    }
    _ = try storage.activate(profile: activeProfile)
    var state = try storage.loadState()
    state.activeProfile = activeProfile
    try storage.saveState(state)

    let backend = FakeRelayBackend(
        storage: storage,
        limitsByAccount: Dictionary(uniqueKeysWithValues: profiles.map { profile in
            (
                "account-\(profile)",
                RateLimitSnapshot(
                    primary: .init(
                        usedPercent: profile == activeProfile ? activeUsedPercent : 10,
                        resetsAt: nil
                    ),
                    secondary: nil,
                    reachedReason: nil,
                    planType: "pro"
                )
            )
        })
    )
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

private func loadAccountQuotas(_ storage: RelayStorage) throws -> AccountQuotaCollection {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
        AccountQuotaCollection.self,
        from: Data(contentsOf: storage.paths.accountQuotas)
    )
}

@Test func importsCurrentChatGPTAccountWithoutRestartingTheApp() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.limitsByAccount["account-c"] = RateLimitSnapshot(
        primary: .init(usedPercent: 12, resetsAt: nil),
        secondary: .init(usedPercent: 34, resetsAt: nil),
        reachedReason: nil, planType: "pro"
    )
    try engineTestAuth(accountID: "account-c", token: "c-token")
        .write(to: harness.storage.paths.activeAuth, options: .atomic)
    let activeAuthBeforeImport = try Data(contentsOf: harness.storage.paths.activeAuth)

    let result = try harness.engine.importCurrentProfile(as: "imported-c")
    let savedConfig = try harness.storage.loadConfig()
    let savedState = try harness.storage.loadState()
    let quotas = try loadAccountQuotas(harness.storage)

    #expect(result.contains("Imported current ChatGPT account"))
    #expect(savedConfig.profiles == ["a", "b", "imported-c"])
    #expect(savedState.activeProfile == "imported-c")
    #expect(try harness.storage.profileAccountID("imported-c") == "account-c")
    #expect(quotas.accounts["imported-c"]?.primary?.usedPercent == 12)
    #expect(try Data(contentsOf: harness.storage.paths.activeAuth) == activeAuthBeforeImport)
    #expect(harness.app.quitCount == 0)
    #expect(harness.app.openCount == 0)
}

@Test func importingAnAlreadyManagedAccountRefreshesItWithoutCreatingADuplicate() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try engineTestAuth(accountID: "account-a", token: "rotated-a-token")
        .write(to: harness.storage.paths.activeAuth, options: .atomic)

    let result = try harness.engine.importCurrentProfile(as: "unused-candidate")
    let storedAuth = try Data(contentsOf: harness.storage.paths.profileAuth("a"))
    let savedConfig = try harness.storage.loadConfig()
    let quotas = try loadAccountQuotas(harness.storage)

    #expect(result.contains("already managed as a"))
    #expect(!harness.storage.profileExists("unused-candidate"))
    #expect(savedConfig.profiles == ["a", "b"])
    #expect(savedConfig.disabledProfiles.isEmpty)
    #expect(engineTestToken(storedAuth) == "rotated-a-token")
    #expect(quotas.accounts["a"]?.primary?.usedPercent == 99)
    #expect(try harness.storage.loadState().activeProfile == "a")
    #expect(harness.app.quitCount == 0)
    #expect(harness.app.openCount == 0)
}

@Test func importingRejectsNonChatGPTCredentialsBeforeCreatingAProfile() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"test-only"}"#.utf8)
        .write(to: harness.storage.paths.activeAuth, options: .atomic)
    let configBeforeImport = try harness.storage.loadConfig()
    let stateBeforeImport = try harness.storage.loadState()

    #expect(throws: RelayError.self) {
        try harness.engine.importCurrentProfile(as: "invalid-import")
    }

    #expect(!harness.storage.profileExists("invalid-import"))
    #expect(harness.backend.rateLimitCalls.isEmpty)
    #expect(try harness.storage.loadConfig() == configBeforeImport)
    #expect(try harness.storage.loadState() == stateBeforeImport)
}

@Test func failedImportVerificationLeavesNoProfileOrConfigurationEntry() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.limitsByAccount["account-c"] = RateLimitSnapshot(
        primary: .init(usedPercent: 12, resetsAt: nil), secondary: nil,
        reachedReason: nil, planType: "pro"
    )
    harness.backend.failuresByAccountCall["account-c"] = [
        1: .rpc("401 Unauthorized: token_invalidated")
    ]
    try engineTestAuth(accountID: "account-c", token: "invalid-c-token")
        .write(to: harness.storage.paths.activeAuth, options: .atomic)
    let configBeforeImport = try harness.storage.loadConfig()
    let stateBeforeImport = try harness.storage.loadState()

    #expect(throws: RelayError.self) {
        try harness.engine.importCurrentProfile(as: "failed-import")
    }

    #expect(!harness.storage.profileExists("failed-import"))
    #expect(try harness.storage.loadConfig() == configBeforeImport)
    #expect(try harness.storage.loadState() == stateBeforeImport)
    #expect(harness.app.quitCount == 0)
    #expect(harness.app.openCount == 0)
}

@Test func manualQuotaRefreshUpdatesEveryProfileWithoutForcingASwitch() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }

    let result = try harness.engine.refreshAllQuotas()
    let quotas = try loadAccountQuotas(harness.storage)

    #expect(result.contains("Refreshed 2 profiles"))
    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(try harness.storage.loadState().activeProfile == "a")
    #expect(try harness.storage.loadState().lastSwitchAt == nil)
    #expect(harness.app.quitCount == 0)
    #expect(harness.app.openCount == 0)
    #expect(harness.backend.rateLimitCalls == ["account-a": 1, "account-b": 1])
    #expect(quotas.accounts["a"]?.primary?.usedPercent == 99)
    #expect(quotas.accounts["b"]?.primary?.usedPercent == 10)
}

@Test func manualQuotaRefreshRecordsPerProfileFailureAndKeepsTheActiveAccount() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.failuresByAccountCall["account-b"] = [
        1: .rpc("503 Service Unavailable")
    ]

    #expect(throws: RelayError.self) {
        try harness.engine.refreshAllQuotas()
    }
    let quotas = try loadAccountQuotas(harness.storage)

    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(harness.app.quitCount == 0)
    #expect(quotas.accounts["a"]?.primary?.usedPercent == 99)
    #expect(quotas.accounts["b"]?.error?.contains("503 Service Unavailable") == true)
}

@Test func failedActiveQuotaRefreshDoesNotOverwriteTheSavedCredential() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let savedCredential = try Data(contentsOf: harness.storage.paths.profileAuth("a"))
    harness.backend.rotatedTokenByAccountCall["account-a"] = [1: "rotated-invalid-token"]
    harness.backend.failuresByAccountCall["account-a"] = [
        1: .rpc("401 Unauthorized: token_invalidated")
    ]

    #expect(throws: RelayError.self) {
        try harness.engine.refreshAllQuotas()
    }

    #expect(try Data(contentsOf: harness.storage.paths.profileAuth("a")) == savedCredential)
    #expect(try Data(contentsOf: harness.storage.paths.activeAuth) != savedCredential)
}

@Test func transientActiveQuotaFailureStillSavesARotatedCredential() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.rotatedTokenByAccountCall["account-a"] = [1: "rotated-valid-token"]
    harness.backend.failuresByAccountCall["account-a"] = [
        1: .rpc("503 Service Unavailable")
    ]

    #expect(throws: RelayError.self) {
        try harness.engine.refreshAllQuotas()
    }

    #expect(
        try Data(contentsOf: harness.storage.paths.profileAuth("a"))
            == Data(contentsOf: harness.storage.paths.activeAuth)
    )
}

@Test func transientStandbyQuotaFailureStillCommitsARotatedCredential() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.rotatedTokenByAccountCall["account-b"] = [1: "b-rotated-valid"]
    harness.backend.failuresByAccountCall["account-b"] = [
        1: .rpc("503 Service Unavailable")
    ]

    #expect(throws: RelayError.self) {
        try harness.engine.refreshAllQuotas()
    }

    #expect(
        engineTestToken(
            try Data(contentsOf: harness.storage.paths.profileAuth("b"))
        ) == "b-rotated-valid"
    )
}

@Test func successfulQuotaRefreshPreservesAnUnrelatedWatchdogError() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    var state = try harness.storage.loadState()
    state.lastError = "pending watchdog recovery"
    try harness.storage.saveState(state)

    _ = try harness.engine.refreshAllQuotas()

    #expect(try harness.storage.loadState().lastError == "pending watchdog recovery")
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

@Test func currentAuthenticationMustFailThreeTimesBeforeFailover() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.failuresByAccountCall["account-a"] = [
        1: .rpc("401 Unauthorized: token_invalidated"),
        2: .rpc("401 Unauthorized: token_invalidated"),
        3: .rpc("401 Unauthorized: token_invalidated"),
    ]
    let savedCredential = try Data(contentsOf: harness.storage.paths.profileAuth("a"))
    harness.backend.rotatedTokenByAccountCall["account-a"] = [1: "rotated-invalid-token"]

    _ = try harness.engine.checkOnce()
    var quotas = try loadAccountQuotas(harness.storage)
    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(quotas.accounts["a"]?.consecutiveAuthenticationFailures == 1)
    #expect(try Data(contentsOf: harness.storage.paths.profileAuth("a")) == savedCredential)

    _ = try harness.engine.checkOnce()
    quotas = try loadAccountQuotas(harness.storage)
    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(quotas.accounts["a"]?.consecutiveAuthenticationFailures == 2)

    _ = try harness.engine.checkOnce()
    quotas = try loadAccountQuotas(harness.storage)

    #expect(try harness.storage.activeAccountID() == "account-b")
    #expect(try harness.storage.loadState().activeProfile == "b")
    #expect(quotas.accounts["a"]?.consecutiveAuthenticationFailures == 3)
    #expect(try Data(contentsOf: harness.storage.paths.profileAuth("a")) == savedCredential)
}

@Test func successfulAuthenticationCheckClearsTheFailureCounter() throws {
    let harness = try makeEngineHarness(activeUsedPercent: 10)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.failuresByAccountCall["account-a"] = [
        1: .rpc("401 Unauthorized: token_invalidated"),
    ]

    _ = try harness.engine.checkOnce()
    #expect(
        try loadAccountQuotas(harness.storage)
            .accounts["a"]?.consecutiveAuthenticationFailures == 1
    )

    _ = try harness.engine.checkOnce()
    let quota = try loadAccountQuotas(harness.storage).accounts["a"]
    #expect(quota?.consecutiveAuthenticationFailures == 0)
    #expect(quota?.error == nil)
    #expect(try harness.storage.activeAccountID() == "account-a")
}

@Test func forbiddenAuthenticationFailureUsesTheRetryBudget() throws {
    let harness = try makeEngineHarness(activeUsedPercent: 10)
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.failuresByAccountCall["account-a"] = [
        1: .rpc("403 Forbidden: authentication required"),
    ]

    let result = try harness.engine.checkOnce()
    let quota = try loadAccountQuotas(harness.storage).accounts["a"]

    #expect(result.contains("authentication failed 1/3"))
    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(quota?.consecutiveAuthenticationFailures == 1)
}

@Test func thirdStandbySingle401IsRetriedWithoutCorruptingItsSavedCredential() throws {
    let harness = try makeEngineHarness(
        profiles: ["a", "b", "c"],
        activeUsedPercent: 10
    )
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let savedCredential = try Data(contentsOf: harness.storage.paths.profileAuth("c"))
    harness.backend.rotatedTokenByAccountCall["account-c"] = [1: "rotated-invalid-token"]
    harness.backend.failuresByAccountCall["account-c"] = [
        1: .rpc("401 Unauthorized: token_invalidated"),
    ]

    _ = try harness.engine.checkOnce(now: now, respectingSchedule: true)
    let quota = try loadAccountQuotas(harness.storage).accounts["c"]

    #expect(quota?.consecutiveAuthenticationFailures == 1)
    #expect(quota?.error?.contains("401 Unauthorized") == true)
    #expect(try Data(contentsOf: harness.storage.paths.profileAuth("c")) == savedCredential)
    #expect(try harness.storage.activeAccountID() == "account-a")
}

@Test func exhaustedAccountDoesNotProbeAStandbyTwiceInOneCheck() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.failuresByAccountCall["account-b"] = [
        1: .rpc("401 Unauthorized: token_invalidated"),
    ]

    #expect(throws: RelayError.self) {
        try harness.engine.checkOnce()
    }
    let quota = try loadAccountQuotas(harness.storage).accounts["b"]

    #expect(harness.backend.rateLimitCalls["account-b"] == 1)
    #expect(quota?.consecutiveAuthenticationFailures == 1)
    #expect(try harness.storage.activeAccountID() == "account-a")
}

@Test func failedCandidateAuthenticationRespectsProgressiveRetryDelays() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let startedAt = Date(timeIntervalSince1970: 2_000_000_000)
    harness.backend.failuresByAccountCall["account-b"] = [
        1: .rpc("401 Unauthorized: token_invalidated"),
        2: .rpc("401 Unauthorized: token_invalidated"),
        3: .rpc("401 Unauthorized: token_invalidated"),
    ]

    #expect(throws: RelayError.self) {
        try harness.engine.checkOnce(now: startedAt, respectingSchedule: true)
    }
    #expect(throws: RelayError.self) {
        try harness.engine.checkOnce(
            now: startedAt.addingTimeInterval(30),
            respectingSchedule: true
        )
    }
    #expect(throws: RelayError.self) {
        try harness.engine.checkOnce(
            now: startedAt.addingTimeInterval(60),
            respectingSchedule: true
        )
    }
    #expect(harness.backend.rateLimitCalls["account-b"] == 2)

    #expect(throws: RelayError.self) {
        try harness.engine.checkOnce(
            now: startedAt.addingTimeInterval(150),
            respectingSchedule: true
        )
    }
    #expect(harness.backend.rateLimitCalls["account-b"] == 3)
}

@Test func scheduledActiveChecksUseAdaptiveIntervals() throws {
    let sampledAt = Date(timeIntervalSince1970: 2_000_000_000)
    for (usedPercent, interval) in [(89, 300.0), (90, 60.0), (98, 30.0)] {
        let harness = try makeEngineHarness(activeUsedPercent: usedPercent)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        for profile in ["a", "b"] {
            try harness.storage.updateAccountQuota(AccountQuotaStatus(
                profile: profile,
                updatedAt: sampledAt,
                primary: .init(
                    usedPercent: profile == "a" ? usedPercent : 10,
                    resetsAt: nil
                ),
                secondary: nil,
                planType: "pro",
                error: nil,
                lastAttemptAt: sampledAt
            ))
        }

        _ = try harness.engine.checkOnce(
            now: sampledAt.addingTimeInterval(interval - 1),
            respectingSchedule: true
        )
        #expect(harness.backend.rateLimitCalls["account-a"] == nil)

        _ = try harness.engine.checkOnce(
            now: sampledAt.addingTimeInterval(interval),
            respectingSchedule: true
        )
        #expect(harness.backend.rateLimitCalls["account-a"] == 1)
    }
}

@Test func standbyAccountsAreNotProbedAgainBeforeTwentyMinutes() throws {
    let harness = try makeEngineHarness(
        profiles: ["a", "b", "c"],
        activeUsedPercent: 10
    )
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let sampledAt = Date(timeIntervalSince1970: 2_000_000_000)
    for profile in ["a", "b", "c"] {
        try harness.storage.updateAccountQuota(AccountQuotaStatus(
            profile: profile,
            updatedAt: sampledAt,
            primary: .init(usedPercent: 10, resetsAt: nil),
            secondary: nil,
            planType: "pro",
            error: nil,
            lastAttemptAt: sampledAt
        ))
    }

    _ = try harness.engine.checkOnce(
        now: sampledAt.addingTimeInterval(10 * 60),
        respectingSchedule: true
    )
    #expect(harness.backend.rateLimitCalls["account-b"] == nil)
    #expect(harness.backend.rateLimitCalls["account-c"] == nil)

    _ = try harness.engine.checkOnce(
        now: sampledAt.addingTimeInterval(20 * 60),
        respectingSchedule: true
    )
    #expect(harness.backend.rateLimitCalls["account-b"] == 1)
    #expect(harness.backend.rateLimitCalls["account-c"] == 1)
}

@Test func rotatedTargetTokenSurvivesTransientValidationFailureAndRetry() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.rotatedTokenByAccountCall["account-b"] = [2: "b-rotated"]
    harness.backend.failuresByAccountCall["account-b"] = [2: .rpc("503 Service Unavailable")]

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
    let savedTargetAuth = try Data(contentsOf: harness.storage.paths.profileAuth("b"))
    harness.backend.rotatedTokenByAccountCall["account-b"] = [2: "b-invalid-rotated"]
    harness.backend.failuresByAccountCall["account-b"] = [
        2: .rpc("401 Unauthorized: token_invalidated")
    ]

    let result = try harness.engine.checkOnce()
    let state = try harness.storage.loadState()

    #expect(result.contains("Rolled back"))
    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(state.activeProfile == "a")
    #expect(state.pendingSwitch == nil)
    #expect(state.lastError?.contains("Target validation failed") == true)
    #expect(harness.app.isRunning)
    #expect(try Data(contentsOf: harness.storage.paths.profileAuth("b")) == savedTargetAuth)
}

@Test func thirdTargetAuthenticationFailurePreservesSavedCredential() throws {
    let harness = try makeEngineHarness(profiles: ["a", "b", "c"])
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.limitsByAccount["account-b"] = RateLimitSnapshot(
        primary: .init(usedPercent: 99, resetsAt: nil),
        secondary: nil,
        reachedReason: nil,
        planType: "pro"
    )
    let savedTargetAuth = try Data(contentsOf: harness.storage.paths.profileAuth("c"))
    harness.backend.rotatedTokenByAccountCall["account-c"] = [2: "c-invalid-rotated"]
    harness.backend.failuresByAccountCall["account-c"] = [
        2: .rpc("401 Unauthorized: token_invalidated")
    ]

    let result = try harness.engine.checkOnce()
    let state = try harness.storage.loadState()

    #expect(result.contains("Rolled back"))
    #expect(try harness.storage.activeAccountID() == "account-a")
    #expect(state.activeProfile == "a")
    #expect(state.pendingSwitch == nil)
    #expect(try Data(contentsOf: harness.storage.paths.profileAuth("c")) == savedTargetAuth)
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

@Test func switchContinuesRecoveryThreadsInsideOneChatGPTWindow() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.recoveryThreads = (1...3).map {
        ThreadRecord(id: "unfinished-thread-\($0)", preview: nil, cwd: "/tmp/\($0)",
                     updatedAt: Int64(Date().timeIntervalSince1970), status: "active")
    }

    _ = try harness.engine.checkOnce()
    Thread.sleep(forTimeInterval: 0.02)
    _ = try harness.engine.checkOnce()

    #expect(harness.app.openCount == 1)
    #expect(harness.backend.wakeAttempts.count == 3)
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

@Test func inProgressRecoveryTurnIsObservedWithoutDuplicateSubmissionOrFailure() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.waitResultStatus = nil

    _ = try harness.engine.checkOnce()
    Thread.sleep(forTimeInterval: 0.02)
    #expect(try harness.storage.loadState().pendingSwitch?.phase == .recovering)
    #expect(harness.backend.wakeAttempts.count == 1)

    _ = try harness.engine.checkOnce()
    let observed = try harness.storage.loadState()
    let key = try #require(observed.pendingSwitch?.snapshot.threads.first?.recoveryKey)

    #expect(harness.backend.wakeAttempts.count == 1)
    #expect(observed.pendingSwitch?.phase == .recovering)
    #expect(observed.pendingSwitch?.recoveryAttempts[key] == nil)
    #expect(observed.failedRecoveryKeys?.contains(key) != true)
}

@Test func lateCompletedRecoveryIsReconciledBeforeFinalizingTheSwitch() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    let entry = RecoveryEntry(
        threadId: "late-completion-thread", cwd: "/tmp", previousStatus: "active",
        recoveryKey: "late-completion-key"
    )
    let transaction = SwitchTransaction(
        snapshot: SwitchSnapshot(
            id: UUID(), createdAt: Date(), sourceProfile: "a", targetProfile: "b",
            threads: [entry]
        ),
        phase: .recovering,
        sourceAccountID: "account-a",
        targetAccountID: "account-b",
        previousLastSwitchAt: nil,
        recoveryAttempts: [entry.recoveryKey: 3]
    )
    _ = try harness.storage.activate(profile: "b")
    try harness.storage.saveState(RelayState(
        activeProfile: "b",
        failedRecoveryKeys: [entry.recoveryKey],
        pendingSwitch: transaction
    ))
    harness.backend.recoveryMarkers[entry.recoveryKey] = .completed

    _ = try harness.engine.checkOnce()
    let reconciled = try harness.storage.loadState()

    #expect(reconciled.pendingSwitch == nil)
    #expect(reconciled.completedRecoveryKeys.contains(entry.recoveryKey))
    #expect(reconciled.failedRecoveryKeys?.contains(entry.recoveryKey) != true)
}

@Test func legacyFailedRecoveryIsRetriedAfterTheRecoveryProtocolUpgrade() throws {
    let harness = try makeEngineHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    harness.backend.waitResultStatus = nil
    let entry = RecoveryEntry(
        threadId: "legacy-failed-thread", cwd: "/tmp", previousStatus: "active",
        recoveryKey: "legacy-failed-key"
    )
    let transaction = SwitchTransaction(
        snapshot: SwitchSnapshot(
            id: UUID(), createdAt: Date(), sourceProfile: "a", targetProfile: "b",
            threads: [entry]
        ),
        phase: .recovering,
        sourceAccountID: "account-a",
        targetAccountID: "account-b",
        previousLastSwitchAt: nil,
        recoveryAttempts: [entry.recoveryKey: 3],
        recoveryProtocolVersion: nil
    )
    _ = try harness.storage.activate(profile: "b")
    try harness.storage.saveState(RelayState(
        activeProfile: "b",
        failedRecoveryKeys: [entry.recoveryKey],
        pendingSwitch: transaction
    ))
    harness.backend.recoveryMarkers[entry.recoveryKey] = .terminalFailure

    _ = try harness.engine.checkOnce()
    let retried = try harness.storage.loadState()

    #expect(harness.backend.wakeAttempts == [entry.recoveryKey])
    #expect(retried.pendingSwitch?.phase == .recovering)
    #expect(retried.pendingSwitch?.recoveryProtocolVersion == 2)
    #expect(retried.failedRecoveryKeys?.contains(entry.recoveryKey) != true)
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
    Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"\#(accountID)","access_token":"\#(token)","refresh_token":"refresh-\#(token)","id_token":"id-\#(token)"}}"#.utf8)
}

private func engineTestToken(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any] else { return nil }
    return tokens["access_token"] as? String
}
