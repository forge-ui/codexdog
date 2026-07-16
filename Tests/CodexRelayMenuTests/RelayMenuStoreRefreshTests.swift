import Foundation
import Testing
@testable import CodexRelayMenu

private actor RefreshGate {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func callCount() -> Int { calls }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor LocalUsageFetchCounter {
    private var calls = 0
    private let snapshot: LocalUsageSnapshot

    init(snapshot: LocalUsageSnapshot) {
        self.snapshot = snapshot
    }

    func fetch() -> LocalUsageSnapshot {
        calls += 1
        return snapshot
    }

    func callCount() -> Int { calls }
}

private final class TestDateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date.addTimeInterval(interval) }
    }
}

private enum RefreshTestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "官方额度暂时不可用" }
}

@Test func quotaRefreshTimeoutScalesWithTheNumberOfProfiles() {
    #expect(RelayQuotaRefreshService.timeoutSeconds(profileCount: 0) == 150)
    #expect(RelayQuotaRefreshService.timeoutSeconds(profileCount: 2) == 225)
    #expect(RelayQuotaRefreshService.timeoutSeconds(profileCount: 10) == 825)
}

@MainActor
@Test func localUsageRefreshBecomesDueAfterThirtyMinutes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let clock = TestDateSource(Date(timeIntervalSince1970: 1_000))
    let usage = LocalUsageSnapshot(
        provider: "codex", source: "test", updatedAt: "now",
        sessionCostUSD: 0, sessionTokens: 0,
        last30DaysCostUSD: 0, last30DaysTokens: 0, daily: []
    )
    let fetchCounter = LocalUsageFetchCounter(snapshot: usage)
    let store = RelayMenuStore(
        startSupervisor: false,
        loadLocalUsage: false,
        startPolling: false,
        rootURL: root,
        dateProvider: { clock.now() },
        localUsageFetcher: { await fetchCounter.fetch() }
    )
    defer {
        store.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    store.refreshLocalUsage(force: true)
    for _ in 0..<100 {
        if await fetchCounter.callCount() == 1, !store.localUsageIsLoading { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fetchCounter.callCount() == 1)

    clock.advance(by: 1_799)
    store.refreshLocalUsage()
    try await Task.sleep(for: .milliseconds(10))
    #expect(await fetchCounter.callCount() == 1)

    clock.advance(by: 1)
    store.refreshLocalUsage()
    for _ in 0..<100 {
        if await fetchCounter.callCount() == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fetchCounter.callCount() == 2)
}

@MainActor
@Test func manualRefreshRunsImmediatelyAndRestartsTheThirtyMinuteWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let clock = TestDateSource(Date(timeIntervalSince1970: 2_000))
    let usage = LocalUsageSnapshot(
        provider: "codex", source: "test", updatedAt: "now",
        sessionCostUSD: 0, sessionTokens: 0,
        last30DaysCostUSD: 0, last30DaysTokens: 0, daily: []
    )
    let fetchCounter = LocalUsageFetchCounter(snapshot: usage)
    let store = RelayMenuStore(
        startSupervisor: false,
        loadLocalUsage: false,
        startPolling: false,
        rootURL: root,
        refreshTiming: MenuRefreshTiming(
            minimumVisibleDuration: .milliseconds(1),
            resultVisibleDuration: .milliseconds(1)
        ),
        dateProvider: { clock.now() },
        localUsageFetcher: { await fetchCounter.fetch() },
        officialQuotaRefresher: { _ in }
    )
    defer {
        store.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    store.refreshLocalUsage(force: true)
    for _ in 0..<100 {
        if await fetchCounter.callCount() == 1, !store.localUsageIsLoading { break }
        try await Task.sleep(for: .milliseconds(5))
    }

    clock.advance(by: 300)
    store.manualRefresh()
    for _ in 0..<100 {
        if await fetchCounter.callCount() == 2, !store.localUsageIsLoading { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fetchCounter.callCount() == 2)

    clock.advance(by: 1_799)
    store.refreshLocalUsage()
    try await Task.sleep(for: .milliseconds(10))
    #expect(await fetchCounter.callCount() == 2)

    clock.advance(by: 1)
    store.refreshLocalUsage()
    for _ in 0..<100 {
        if await fetchCounter.callCount() == 3 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fetchCounter.callCount() == 3)
}

@MainActor
@Test func manualRefreshCoalescesRepeatedClicksAndPublishesProgress() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let gate = RefreshGate()
    let usage = LocalUsageSnapshot(
        provider: "codex", source: "test", updatedAt: "now",
        sessionCostUSD: 0, sessionTokens: 0,
        last30DaysCostUSD: 0, last30DaysTokens: 0, daily: []
    )
    let store = RelayMenuStore(
        startSupervisor: false,
        loadLocalUsage: false,
        startPolling: false,
        rootURL: root,
        refreshTiming: MenuRefreshTiming(
            minimumVisibleDuration: .milliseconds(10),
            resultVisibleDuration: .seconds(5)
        ),
        localUsageFetcher: { usage },
        officialQuotaRefresher: { _ in await gate.wait() }
    )
    defer {
        store.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    store.manualRefresh()
    store.manualRefresh()
    #expect(store.refreshPhase == .refreshing)

    for _ in 0..<100 {
        if await gate.callCount() > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let callsBeforeRelease = await gate.callCount()
    #expect(callsBeforeRelease == 1)

    await gate.open()
    for _ in 0..<100 {
        if store.refreshPhase == .succeeded { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.refreshPhase == .succeeded)

    store.shutdown()
    #expect(store.refreshPhase == .idle)
}

@MainActor
@Test func manualRefreshPublishesFailureStatusAndDetail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let usage = LocalUsageSnapshot(
        provider: "codex", source: "test", updatedAt: "now",
        sessionCostUSD: 0, sessionTokens: 0,
        last30DaysCostUSD: 0, last30DaysTokens: 0, daily: []
    )
    let store = RelayMenuStore(
        startSupervisor: false,
        loadLocalUsage: false,
        startPolling: false,
        rootURL: root,
        refreshTiming: MenuRefreshTiming(
            minimumVisibleDuration: .milliseconds(10),
            resultVisibleDuration: .seconds(5)
        ),
        localUsageFetcher: { usage },
        officialQuotaRefresher: { _ in throw RefreshTestError.unavailable }
    )
    defer {
        store.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    store.manualRefresh()
    for _ in 0..<100 {
        if store.refreshPhase == .failed { break }
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(store.refreshPhase == .failed)
    #expect(store.message == "刷新失败：官方额度暂时不可用")
}

@MainActor
@Test func watchdogAndOperationErrorsRemainVisibleTogether() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = RelayMenuStore(
        startSupervisor: false,
        loadLocalUsage: false,
        startPolling: false,
        rootURL: root
    )
    defer {
        store.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
    store.state = MenuRelayState(
        activeProfile: nil, lastSwitchAt: nil, lastError: "看门狗恢复失败"
    )
    store.message = "刷新失败：网络不可用"

    #expect(store.visibleErrors == ["看门狗恢复失败", "刷新失败：网络不可用"])
}
