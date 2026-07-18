import CryptoKit
import Foundation
import Testing
@testable import CodexUsageCore

@Test func builtInScannerAggregatesCodexTokensAndCost() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let timestamp = "2026-07-18T10:00:00Z"

    try fixture.writeSession(
        name: "rollout-2026-07-18T10-00-00-root.jsonl",
        lines: [
            sessionMeta(id: "root", timestamp: timestamp),
            turnContext(model: "gpt-5.5", timestamp: timestamp),
            tokenCount(
                timestamp: timestamp,
                total: (input: 1_000, cached: 200, output: 100),
                last: (input: 1_000, cached: 200, output: 100)
            ),
            tokenCount(
                timestamp: "2026-07-18T10:01:00Z",
                total: (input: 1_500, cached: 300, output: 200),
                last: (input: 500, cached: 100, output: 100)
            ),
        ]
    )

    let cold = try fixture.scan(now: now, forceRescan: true)
    #expect(cold.todayTokens == 1_700)
    #expect(cold.last30DaysTokens == 1_700)
    #expect(abs((cold.todayCostUSD ?? 0) - 0.01215) < 0.000_001)
    #expect(cold.daily.count == 1)
    #expect(cold.daily[0].modelBreakdowns == [
        CodexUsageModelBreakdown(modelName: "gpt-5.5", totalTokens: 1_700),
    ])
    let warm = try fixture.scan(now: now.addingTimeInterval(61), forceRescan: false)
    expectSameUsage(warm, cold)
}

@Test func copiedSubagentPrefixIsNotCountedTwice() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let timestamp = "2026-07-18T10:00:00Z"

    let parentLines = [
        sessionMeta(id: "parent", timestamp: timestamp),
        turnContext(model: "gpt-5.5", timestamp: timestamp),
        tokenCount(
            timestamp: timestamp,
            total: (input: 1_000, cached: 200, output: 100),
            last: (input: 1_000, cached: 200, output: 100)
        ),
    ]
    try fixture.writeSession(name: "rollout-2026-07-18T10-00-00-parent.jsonl", lines: parentLines)
    try fixture.writeSession(
        name: "rollout-2026-07-18T10-02-00-child.jsonl",
        lines: [
            sessionMeta(
                id: "child",
                timestamp: timestamp,
                source: ["subagent": ["thread_spawn": [:]]],
                forkedFromID: "parent"
            ),
            sessionMeta(id: "parent", timestamp: timestamp),
            turnContext(model: "gpt-5.5", timestamp: timestamp),
            parentLines[2],
            turnContext(model: "gpt-5.5", timestamp: "2026-07-18T10:02:00Z"),
            jsonLine([
                "timestamp": "2026-07-18T10:02:00Z",
                "type": "inter_agent_communication_metadata",
                "payload": ["trigger_turn": true],
            ]),
            tokenCount(
                timestamp: "2026-07-18T10:03:00Z",
                total: (input: 1_400, cached: 250, output: 150),
                last: (input: 400, cached: 50, output: 50)
            ),
        ]
    )

    let cold = try fixture.scan(now: now, forceRescan: true)
    let warm = try fixture.scan(now: now.addingTimeInterval(61), forceRescan: false)
    #expect(cold.last30DaysTokens == 1_550)
    expectSameUsage(warm, cold)
}

@Test func activeAndArchivedCopiesOfOneSessionAreDeduplicated() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let lines = [
        sessionMeta(id: "same-session", timestamp: "2026-07-18T10:00:00Z"),
        turnContext(model: "gpt-5.5", timestamp: "2026-07-18T10:00:00Z"),
        tokenCount(
            timestamp: "2026-07-18T10:00:00Z",
            total: (input: 800, cached: 100, output: 100),
            last: (input: 800, cached: 100, output: 100)
        ),
    ]
    let name = "rollout-2026-07-18T10-00-00-same.jsonl"
    try fixture.writeSession(name: name, lines: lines)
    try fixture.writeSession(name: name, lines: lines, archived: true)

    let snapshot = try fixture.scan(now: now, forceRescan: true)
    #expect(snapshot.last30DaysTokens == 900)
    let warm = try fixture.scan(now: now.addingTimeInterval(61), forceRescan: false)
    expectSameUsage(warm, snapshot)
}

@Test func interleavedCumulativeCountersDoNotRecountTheGap() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let timestamp = "2026-07-18T10:00:00Z"
    try fixture.writeSession(
        name: "rollout-2026-07-18T10-00-00-interleaved.jsonl",
        lines: [
            sessionMeta(id: "interleaved", timestamp: timestamp),
            turnContext(model: "gpt-5.5", timestamp: timestamp),
            tokenCount(timestamp: timestamp, total: (100, 0, 0), last: (100, 0, 0)),
            tokenCount(timestamp: "2026-07-18T10:01:00Z", total: (5, 0, 0), last: (5, 0, 0)),
            tokenCount(timestamp: "2026-07-18T10:02:00Z", total: (101, 0, 0), last: (96, 0, 0)),
        ]
    )

    let snapshot = try fixture.scan(now: now, forceRescan: true)
    #expect(snapshot.last30DaysTokens == 101)
    let warm = try fixture.scan(now: now.addingTimeInterval(61), forceRescan: false)
    expectSameUsage(warm, snapshot)
}

@Test func growingSubagentIsReclassifiedInsteadOfAppendingCopiedHistory() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let timestamp = "2026-07-18T10:00:00Z"
    let name = "rollout-2026-07-18T10-00-00-growing-child.jsonl"
    try fixture.writeSession(
        name: name,
        lines: [
            sessionMeta(
                id: "growing-child",
                timestamp: timestamp,
                source: ["subagent": ["thread_spawn": [:]]]
            ),
            turnContext(model: "gpt-5.5", timestamp: timestamp),
            tokenCount(timestamp: timestamp, total: (1_000, 0, 0), last: (1_000, 0, 0)),
        ]
    )
    let before = try fixture.scan(now: now, forceRescan: true)
    #expect(before.last30DaysTokens == 1_000)

    try fixture.appendSession(
        name: name,
        lines: [
            sessionMeta(id: "ancestor", timestamp: timestamp),
            turnContext(model: "gpt-5.5", timestamp: "2026-07-18T10:01:00Z"),
            jsonLine([
                "timestamp": "2026-07-18T10:01:00Z",
                "type": "inter_agent_communication_metadata",
                "payload": ["trigger_turn": true],
            ]),
            tokenCount(
                timestamp: "2026-07-18T10:02:00Z",
                total: (1_050, 0, 0),
                last: (50, 0, 0)
            ),
        ]
    )

    let after = try fixture.scan(now: now.addingTimeInterval(61), forceRescan: false)
    #expect(after.last30DaysTokens == 50)
}

@Test func unresolvedForkSkipsItsInheritedFirstSnapshot() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let timestamp = "2026-07-18T10:00:00Z"
    try fixture.writeSession(
        name: "rollout-2026-07-18T10-00-00-missing-parent.jsonl",
        lines: [
            sessionMeta(
                id: "missing-parent-child",
                timestamp: timestamp,
                forkedFromID: "parent-not-present"
            ),
            turnContext(model: "gpt-5.5", timestamp: timestamp),
            tokenCount(timestamp: timestamp, total: (100, 0, 0), last: (100, 0, 0)),
            tokenCount(timestamp: "2026-07-18T10:01:00Z", total: (110, 0, 0), last: (10, 0, 0)),
        ]
    )

    let snapshot = try fixture.scan(now: now, forceRescan: true)
    #expect(snapshot.last30DaysTokens == 10)
    let warm = try fixture.scan(now: now.addingTimeInterval(61), forceRescan: false)
    expectSameUsage(warm, snapshot)
}

@Test func missingCodexHomeReturnsAnEmptySnapshot() throws {
    let fixture = try UsageFixture(createSessionsDirectory: false)
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let snapshot = try fixture.scan(now: now, forceRescan: true)
    #expect(snapshot.todayTokens == 0)
    #expect(snapshot.last30DaysTokens == 0)
    #expect(snapshot.todayCostUSD == nil)
    #expect(snapshot.last30DaysCostUSD == nil)
    #expect(snapshot.daily.isEmpty)
}

@Test func existingEmptySessionsDirectoryReturnsNoUsage() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))

    let snapshot = try fixture.scan(now: now, forceRescan: true)
    #expect(snapshot.todayTokens == 0)
    #expect(snapshot.todayCostUSD == nil)
    #expect(snapshot.last30DaysCostUSD == nil)
    #expect(snapshot.daily.isEmpty)
}

@Test func archivedOnlySessionIsIncluded() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    try fixture.writeSession(
        name: "rollout-2026-07-18T10-00-00-archived.jsonl",
        lines: [
            sessionMeta(id: "archived", timestamp: "2026-07-18T10:00:00Z"),
            turnContext(model: "gpt-5.5", timestamp: "2026-07-18T10:00:00Z"),
            tokenCount(
                timestamp: "2026-07-18T10:00:00Z",
                total: (250, 50, 25),
                last: (250, 50, 25)
            ),
        ],
        archived: true
    )

    let snapshot = try fixture.scan(now: now, forceRescan: true)
    #expect(snapshot.last30DaysTokens == 275)
}

@Test func warmRefreshRemovesUsageWhenSourceLogIsDeleted() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let file = try fixture.writeSession(
        name: "rollout-2026-07-18T10-00-00-deleted.jsonl",
        lines: [
            sessionMeta(id: "deleted", timestamp: "2026-07-18T10:00:00Z"),
            turnContext(model: "gpt-5.5", timestamp: "2026-07-18T10:00:00Z"),
            tokenCount(
                timestamp: "2026-07-18T10:00:00Z",
                total: (300, 0, 0),
                last: (300, 0, 0)
            ),
        ]
    )
    #expect(try fixture.scan(now: now, forceRescan: true).last30DaysTokens == 300)

    try FileManager.default.removeItem(at: file)
    let refreshed = try fixture.scan(now: now.addingTimeInterval(61), forceRescan: false)
    #expect(refreshed.last30DaysTokens == 0)
    #expect(refreshed.daily.isEmpty)
}

@Test func warmRefreshFindsOldSessionResumedToday() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    try fixture.writeSession(
        name: "rollout-2026-07-18T09-00-00-seed.jsonl",
        lines: [
            sessionMeta(id: "seed", timestamp: "2026-07-18T09:00:00Z"),
            turnContext(model: "gpt-5.5", timestamp: "2026-07-18T09:00:00Z"),
            tokenCount(timestamp: "2026-07-18T09:00:00Z", total: (100, 0, 0), last: (100, 0, 0)),
        ]
    )
    #expect(try fixture.scan(now: now, forceRescan: true).last30DaysTokens == 100)

    let resumedFile = try fixture.writeSession(
        name: "rollout-2026-05-01T09-00-00-resumed.jsonl",
        lines: [
            sessionMeta(id: "resumed", timestamp: "2026-05-01T09:00:00Z"),
            turnContext(model: "gpt-5.5", timestamp: "2026-07-18T11:00:00Z"),
            tokenCount(timestamp: "2026-07-18T11:00:00Z", total: (75, 0, 0), last: (75, 0, 0)),
        ]
    )
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(30)],
        ofItemAtPath: resumedFile.path
    )
    let refreshed = try fixture.scan(now: now.addingTimeInterval(61), forceRescan: false)
    #expect(refreshed.last30DaysTokens == 175)
}

@Test func rollingWindowAdvanceReusesUnchangedCachedFiles() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let file = try fixture.writeSession(
        name: "rollout-2026-07-18T09-00-00-cross-day.jsonl",
        lines: [
            sessionMeta(id: "cross-day", timestamp: "2026-07-18T09:00:00Z"),
            turnContext(model: "gpt-5.5", timestamp: "2026-07-18T09:00:00Z"),
            tokenCount(timestamp: "2026-07-18T09:00:00Z", total: (125, 0, 0), last: (125, 0, 0)),
        ]
    )
    let cold = try fixture.scan(now: now, forceRescan: false)
    #expect(cold.last30DaysTokens == 125)

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    let nextDay = try fixture.scan(now: now.addingTimeInterval(24 * 60 * 60), forceRescan: false)
    #expect(nextDay.last30DaysTokens == 125)
    let refreshedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: fixture.cache)
    #expect(refreshedCache.scanSinceKey == "2026-06-19")
}

@Test func compatibleCacheProducerIsAcceptedAndUnknownProducerIsRejected() throws {
    let fixture = try UsageFixture()
    defer { fixture.remove() }
    var cache = CostUsageCache()
    cache.lastScanUnixMs = 42
    CostUsageCacheIO.save(
        provider: .codex,
        cache: cache,
        cacheRoot: fixture.cache,
        producerKey: "codex:cu:pa691a2a2543475d8"
    )
    #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: fixture.cache).lastScanUnixMs == 42)

    cache.lastScanUnixMs = 99
    CostUsageCacheIO.save(
        provider: .codex,
        cache: cache,
        cacheRoot: fixture.cache,
        producerKey: "codex:cu:punrelated"
    )
    #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: fixture.cache).lastScanUnixMs == 0)
}

@Test func parserHashMatchesEmbeddedCoreSources() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceRoot = repositoryRoot.appendingPathComponent("Sources/CodexUsageCore", isDirectory: true)
    let enumerator = try #require(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
    var files: [URL] = []
    while let file = enumerator.nextObject() as? URL {
        guard file.pathExtension == "swift", file.lastPathComponent != "CodexParserHash.generated.swift" else {
            continue
        }
        files.append(file)
    }
    files.sort { $0.path < $1.path }
    let manifest = try files.map { file -> String in
        let data = try Data(contentsOf: file)
        let relativePath = String(file.path.dropFirst(repositoryRoot.path.count + 1))
        return "\(sha256Hex(data))  \(relativePath)\n"
    }.joined()
    let expected = String(sha256Hex(Data(manifest.utf8)).prefix(16))
    #expect(CodexParserHash.value == expected)
}

private struct UsageFixture {
    let root: URL
    let sessions: URL
    let archived: URL
    let cache: URL

    init(createSessionsDirectory: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexDogUsageTests-\(UUID().uuidString)", isDirectory: true)
        sessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        archived = root.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        if createSessionsDirectory {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func writeSession(name: String, lines: [String], archived isArchived: Bool = false) throws -> URL {
        let directory = isArchived ? archived : sessions
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    func appendSession(name: String, lines: [String]) throws {
        let url = sessions.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    func scan(now: Date, forceRescan: Bool) throws -> CodexUsageSnapshot {
        try CodexUsageClient.scan(
            historyDays: 30,
            now: now,
            codexSessionsRoot: sessions,
            cacheRoot: cache,
            codexTraceDatabaseURL: root.appendingPathComponent("missing-logs.sqlite"),
            forceRescan: forceRescan
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func sessionMeta(
    id: String,
    timestamp: String,
    source: Any = "cli",
    forkedFromID: String? = nil
) -> String {
    var payload: [String: Any] = [
        "id": id,
        "timestamp": timestamp,
        "source": source,
        "cwd": "/tmp/codexdog-fixture",
    ]
    if let forkedFromID { payload["forked_from_id"] = forkedFromID }
    return jsonLine(["timestamp": timestamp, "type": "session_meta", "payload": payload])
}

private func turnContext(model: String, timestamp: String) -> String {
    jsonLine([
        "timestamp": timestamp,
        "type": "turn_context",
        "payload": ["model": model],
    ])
}

private func tokenCount(
    timestamp: String,
    total: (input: Int, cached: Int, output: Int),
    last: (input: Int, cached: Int, output: Int)
) -> String {
    func usage(_ value: (input: Int, cached: Int, output: Int)) -> [String: Int] {
        [
            "input_tokens": value.input,
            "cached_input_tokens": value.cached,
            "output_tokens": value.output,
        ]
    }
    return jsonLine([
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "total_token_usage": usage(total),
                "last_token_usage": usage(last),
            ],
        ],
    ])
}

private func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func expectSameUsage(_ lhs: CodexUsageSnapshot, _ rhs: CodexUsageSnapshot) {
    #expect(lhs.todayCostUSD == rhs.todayCostUSD)
    #expect(lhs.todayTokens == rhs.todayTokens)
    #expect(lhs.last30DaysCostUSD == rhs.last30DaysCostUSD)
    #expect(lhs.last30DaysTokens == rhs.last30DaysTokens)
    #expect(lhs.daily == rhs.daily)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
