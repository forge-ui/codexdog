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
