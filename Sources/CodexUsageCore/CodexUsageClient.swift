import Foundation

public struct CodexUsageSnapshot: Sendable, Equatable {
    public let updatedAt: Date
    public let todayCostUSD: Double?
    public let todayTokens: Int64
    public let last30DaysCostUSD: Double?
    public let last30DaysTokens: Int64
    public let daily: [CodexUsageDay]
}

public struct CodexUsageDay: Sendable, Equatable {
    public let date: String
    public let totalTokens: Int64
    public let totalCostUSD: Double
    public let modelBreakdowns: [CodexUsageModelBreakdown]
}

public struct CodexUsageModelBreakdown: Sendable, Equatable {
    public let modelName: String
    public let totalTokens: Int64
}

public enum CodexUsageClient {
    public static func scan(
        historyDays: Int = 30,
        now: Date = Date(),
        codexSessionsRoot: URL? = nil,
        cacheRoot: URL? = nil,
        codexTraceDatabaseURL: URL? = nil,
        forceRescan: Bool = false
    ) throws -> CodexUsageSnapshot {
        let safeHistoryDays = max(1, historyDays)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -(safeHistoryDays - 1), to: today) ?? today
        let options = CostUsageScanner.Options(
            codexSessionsRoot: codexSessionsRoot,
            cacheRoot: cacheRoot,
            codexTraceDatabaseURL: codexTraceDatabaseURL,
            forceRescan: forceRescan
        )
        let report = try CostUsageScanner.loadDailyReportCancellable(
            provider: .codex,
            since: since,
            until: now,
            now: now,
            options: options,
            checkCancellation: { try Task.checkCancellation() }
        )

        let daily = report.data.map { entry in
            CodexUsageDay(
                date: entry.date,
                totalTokens: Int64(entry.totalTokens ?? 0),
                totalCostUSD: entry.costUSD ?? 0,
                modelBreakdowns: (entry.modelBreakdowns ?? []).map {
                    CodexUsageModelBreakdown(
                        modelName: $0.modelName,
                        totalTokens: Int64($0.totalTokens ?? 0)
                    )
                }
            )
        }
        let todayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: today)
        let todayEntry = report.data.first(where: { $0.date == todayKey })
        let pricedEntries = report.data.compactMap(\.costUSD)

        return CodexUsageSnapshot(
            updatedAt: now,
            todayCostUSD: todayEntry?.costUSD,
            todayTokens: Int64(todayEntry?.totalTokens ?? 0),
            last30DaysCostUSD: pricedEntries.isEmpty ? nil : pricedEntries.reduce(0, +),
            last30DaysTokens: daily.reduce(0) { $0 + $1.totalTokens },
            daily: daily
        )
    }
}
