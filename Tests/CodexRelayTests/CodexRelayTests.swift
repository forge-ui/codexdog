import Foundation
import Testing
@testable import CodexRelay

@Test func advisoryLockSerializesIndependentFileDescriptorsAndReleasesAfterScope() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = RelayAdvisoryLock(root: root)

    let firstLease = try lock.acquire()
    #expect(try lock.tryAcquire() == nil)
    firstLease.release()

    let secondLease = try lock.tryAcquire()
    #expect(secondLease != nil)
    secondLease?.release()

    enum ExpectedFailure: Error { case failed }
    #expect(throws: ExpectedFailure.self) {
        try lock.withLock { throw ExpectedFailure.failed }
    }
    let afterThrow = try lock.tryAcquire()
    #expect(afterThrow != nil)
    afterThrow?.release()
}

@Test func thresholdUsesEitherWindowOrReachedReason() {
    #expect(RateLimitSnapshot(primary: .init(usedPercent: 99, resetsAt: nil), secondary: nil, reachedReason: nil, planType: "pro").isExhausted(threshold: 99))
    #expect(RateLimitSnapshot(primary: .init(usedPercent: 20, resetsAt: nil), secondary: .init(usedPercent: 100, resetsAt: nil), reachedReason: nil, planType: "pro").isExhausted(threshold: 99))
    #expect(RateLimitSnapshot(primary: nil, secondary: nil, reachedReason: "rate_limit_reached", planType: "pro").isExhausted(threshold: 99))
    #expect(!RateLimitSnapshot(primary: .init(usedPercent: 98, resetsAt: nil), secondary: nil, reachedReason: nil, planType: "pro").isExhausted(threshold: 99))
    #expect(!RateLimitSnapshot(primary: nil, secondary: nil, reachedReason: nil, planType: "pro").hasOfficialLimitSignal)
}

@Test func profileRotationSupportsAnyNumberOfAccounts() {
    let profiles = ["one", "two", "three", "four"]
    #expect(ProfileRotation.candidates(profiles: profiles, current: "two") == ["three", "four", "one"])
    #expect(ProfileRotation.candidates(profiles: profiles, current: "four") == ["one", "two", "three"])
    #expect(ProfileRotation.candidates(profiles: ["only"], current: "only").isEmpty)
    #expect(ProfileRotation.candidates(profiles: ["two", "three"], current: "paused") == ["two", "three"])
}

@Test func schedulingCanPauseResumeAndRemoveProfiles() {
    var config = RelayConfig(profiles: ["one", "two", "three"])
    config.setProfile("two", scheduled: false)
    #expect(config.scheduledProfiles == ["one", "three"])
    #expect(!config.isProfileScheduled("two"))

    config.setProfile("two", scheduled: true)
    #expect(config.scheduledProfiles == ["one", "two", "three"])

    config.setProfile("three", scheduled: false)
    config.removeProfile("three")
    #expect(config.profiles == ["one", "two"])
    #expect(config.disabledProfiles.isEmpty)
}

@Test func legacyConfigDecodesWithSchedulingEnabled() throws {
    let data = Data(#"{"profiles":["one","two"],"dryRun":false}"#.utf8)
    let config = try JSONDecoder().decode(RelayConfig.self, from: data)
    #expect(config.scheduledProfiles == ["one", "two"])
    #expect(config.thresholdUsedPercent == 99)
    #expect(!config.dryRun)
}

@Test func recoverySelectsRecentAndActiveThreads() {
    let now = Date(timeIntervalSince1970: 10_000)
    let threads = [
        ThreadRecord(id: "active", preview: nil, cwd: "/a", updatedAt: 1, status: "active"),
        ThreadRecord(id: "recent", preview: nil, cwd: "/b", updatedAt: 9_999, status: "notLoaded"),
        ThreadRecord(id: "old", preview: nil, cwd: "/c", updatedAt: 1, status: "notLoaded")
    ]
    let result = RecoverySelector.select(threads, now: now, recentHours: 1, maxCount: 20, completedKeys: [], switchID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    #expect(result.map(\.threadId) == ["active", "recent"])
}

@Test func profileActivationIsAtomicAndPreservesPreviousAuth() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let codex = root.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let config = RelayConfig(codexHome: codex.path)
    let storage = RelayStorage(paths: RelayPaths(config: config, rootOverride: root.appendingPathComponent("relay")))
    try storage.bootstrap()
    try authData(accountID: "account-a", token: "A").write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "a")
    try authData(accountID: "account-b", token: "B").write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "b")
    let previous = try storage.activate(profile: "a")
    #expect(authAccountID(previous) == "account-b")
    #expect(try storage.activeAccountID() == "account-a")
    #expect(try storage.assertActiveAccount(matchesProfile: "a") == "account-a")
}

@Test func activeProfileIsDetectedWithoutExposingToken() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let codex = root.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let config = RelayConfig(codexHome: codex.path)
    let storage = RelayStorage(paths: RelayPaths(config: config, rootOverride: root.appendingPathComponent("relay")))
    try storage.bootstrap()
    let auth = Data(#"{"tokens":{"account_id":"account-123","access_token":"secret"}}"#.utf8)
    try auth.write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "a")
    #expect(storage.detectActiveProfile(in: ["a", "b"]) == "a")
}

@Test func refreshedActiveCredentialReplacesStoredProfileCopy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let storage = RelayStorage(paths: RelayPaths(
        config: RelayConfig(codexHome: codex.path),
        rootOverride: root.appendingPathComponent("relay")))
    try storage.bootstrap()

    try authData(accountID: "account", token: "old-token").write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "account")
    try authData(accountID: "account", token: "rotated-token").write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "account")

    let stored = try Data(contentsOf: storage.paths.profileAuth("account"))
    #expect(authToken(stored) == "rotated-token")
}

@Test func concurrentAccountChangeCannotOverwriteStoredProfileIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let storage = RelayStorage(paths: RelayPaths(
        config: RelayConfig(codexHome: codex.path),
        rootOverride: root.appendingPathComponent("relay")))
    try storage.bootstrap()

    try authData(accountID: "account-a", token: "a-token").write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "profile-a")

    // Simulate ChatGPT or another relay process switching the shared auth after
    // the engine identified profile-a but before it attempted the token sync.
    try authData(accountID: "account-b", token: "b-token").write(to: storage.paths.activeAuth)
    #expect(throws: RelayError.self) {
        try storage.saveCurrentAuth(as: "profile-a")
    }

    #expect(try storage.profileAccountID("profile-a") == "account-a")
    #expect(try storage.activeAccountID() == "account-b")
    #expect(authToken(try Data(contentsOf: storage.paths.profileAuth("profile-a"))) == "a-token")
}

@Test func expectedIdentityPreventsImportingAChangedActiveAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let storage = RelayStorage(paths: RelayPaths(
        config: RelayConfig(codexHome: codex.path),
        rootOverride: root.appendingPathComponent("relay")))
    try storage.bootstrap()
    try authData(accountID: "account-b", token: "b-token")
        .write(to: storage.paths.activeAuth)

    #expect(throws: RelayError.self) {
        try storage.saveCurrentAuth(as: "new-profile", expectedAccountID: "account-a")
    }

    #expect(!storage.profileExists("new-profile"))
    #expect(try storage.activeAccountID() == "account-b")
}

@Test func deletingProfileRemovesCredentialAndCachedQuota() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let storage = RelayStorage(paths: RelayPaths(
        config: RelayConfig(codexHome: codex.path),
        rootOverride: root.appendingPathComponent("relay")))
    try storage.bootstrap()

    try Data(#"{"tokens":{"account_id":"delete-me"}}"#.utf8).write(to: storage.paths.activeAuth)
    try storage.saveCurrentAuth(as: "profile")
    try storage.updateAccountQuota(AccountQuotaStatus(
        profile: "profile", updatedAt: Date(), primary: nil, secondary: nil,
        planType: "pro", error: nil))

    try storage.deleteProfile("profile")
    #expect(!storage.profileExists("profile"))
    let quotaData = try Data(contentsOf: storage.paths.accountQuotas)
    let quotas = try JSONDecoder().decode(AccountQuotaCollection.self, from: quotaData)
    #expect(quotas.accounts["profile"] == nil)
}

private func authData(accountID: String, token: String) -> Data {
    Data(#"{"tokens":{"account_id":"\#(accountID)","access_token":"\#(token)"}}"#.utf8)
}

private func authAccountID(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = object["tokens"] as? [String: Any] else { return nil }
    return tokens["account_id"] as? String
}

private func authToken(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = object["tokens"] as? [String: Any] else { return nil }
    return tokens["access_token"] as? String
}
