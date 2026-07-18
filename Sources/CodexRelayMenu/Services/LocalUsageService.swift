import CodexUsageCore
import Foundation

enum LocalUsageServiceError: LocalizedError {
    case scannerFailed(String)

    var errorDescription: String? {
        switch self {
        case .scannerFailed(let message):
            return message.isEmpty ? "本机用量扫描失败" : message
        }
    }
}

struct LocalUsageService {
    static func fetch() async throws -> LocalUsageSnapshot {
        let scanTask = Task.detached(priority: .utility) {
            try CodexUsageClient.scan(historyDays: 30)
        }

        do {
            let scanned = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: CodexUsageSnapshot.self) { group in
                    group.addTask {
                        try await withTaskCancellationHandler {
                            try await scanTask.value
                        } onCancel: {
                            scanTask.cancel()
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(15 * 60))
                        throw LocalUsageServiceError.scannerFailed("本机用量扫描超过 15 分钟")
                    }
                    guard let first = try await group.next() else {
                        throw LocalUsageServiceError.scannerFailed("没有读取到本机用量")
                    }
                    group.cancelAll()
                    return first
                }
            } onCancel: {
                scanTask.cancel()
            }
            scanTask.cancel()
            return map(scanned)
        } catch is CancellationError {
            scanTask.cancel()
            throw CancellationError()
        } catch let error as LocalUsageServiceError {
            scanTask.cancel()
            throw error
        } catch {
            scanTask.cancel()
            throw LocalUsageServiceError.scannerFailed(error.localizedDescription)
        }
    }

    private static func map(_ snapshot: CodexUsageSnapshot) -> LocalUsageSnapshot {
        LocalUsageSnapshot(
            provider: "codex",
            source: "codexdog-local",
            updatedAt: iso8601(snapshot.updatedAt),
            sessionCostUSD: snapshot.todayCostUSD,
            sessionTokens: snapshot.todayTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: snapshot.last30DaysTokens,
            daily: snapshot.daily.map { day in
                LocalUsageDay(
                    date: day.date,
                    totalTokens: day.totalTokens,
                    totalCost: day.totalCostUSD,
                    modelBreakdowns: day.modelBreakdowns.map {
                        LocalUsageModelBreakdown(
                            modelName: $0.modelName,
                            totalTokens: $0.totalTokens
                        )
                    }
                )
            }
        )
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
