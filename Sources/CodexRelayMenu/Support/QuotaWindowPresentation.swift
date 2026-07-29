import Foundation

enum QuotaWindowSource: String, Hashable {
    case primary
    case secondary
}

struct QuotaWindowRow: Identifiable {
    let source: QuotaWindowSource
    let title: String
    let window: MenuQuotaWindow

    var id: QuotaWindowSource { source }
}

enum QuotaWindowPresentation {
    static func rows(for quota: MenuAccountQuota?) -> [QuotaWindowRow] {
        guard let quota else { return [] }
        let windows: [(source: QuotaWindowSource, window: MenuQuotaWindow)] = [
            quota.primary.map { (.primary, $0) },
            quota.secondary.map { (.secondary, $0) },
        ]
        .compactMap { $0 }
        .sorted { lhs, rhs in
            sortValue(lhs.window, source: lhs.source) < sortValue(rhs.window, source: rhs.source)
        }

        return windows.enumerated().map { index, entry in
            QuotaWindowRow(
                source: entry.source,
                title: title(
                    durationMinutes: entry.window.windowDurationMins,
                    fallbackIndex: windows.count > 1 ? index + 1 : nil
                ),
                window: entry.window
            )
        }
    }

    static func paceDescription(
        for window: MenuQuotaWindow?,
        sampledAt: Date?,
        now: Date = Date()
    ) -> String? {
        guard let window,
              let sampledAt,
              let resetsAt = window.resetsAt,
              let durationMinutes = window.windowDurationMins,
              durationMinutes > 0
        else {
            return nil
        }

        let duration = TimeInterval(durationMinutes) * 60
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let timeUntilResetAtSample = resetDate.timeIntervalSince(sampledAt)
        guard resetDate > now,
              timeUntilResetAtSample > 0,
              timeUntilResetAtSample <= duration
        else {
            return nil
        }

        let usedPercent = Double(max(0, min(100, window.usedPercent)))
        if usedPercent >= 100 { return "预计已耗尽" }

        let elapsed = duration - timeUntilResetAtSample
        guard elapsed > 0, elapsed / duration >= 0.03 else { return nil }
        guard usedPercent > 0 else { return "预计可支撑至重置" }

        let secondsUntilExhaustedAtSample = (100 - usedPercent) * elapsed / usedPercent
        guard secondsUntilExhaustedAtSample.isFinite,
              secondsUntilExhaustedAtSample >= 0
        else {
            return nil
        }

        let exhaustionDate = sampledAt.addingTimeInterval(secondsUntilExhaustedAtSample)
        guard exhaustionDate < resetDate else {
            return "预计可支撑至重置"
        }

        let secondsUntilExhausted = exhaustionDate.timeIntervalSince(now)
        guard secondsUntilExhausted > 0 else { return "预计已耗尽" }
        return "预计 \(compactDuration(secondsUntilExhausted)) 后耗尽"
    }

    private static func sortValue(_ window: MenuQuotaWindow, source: QuotaWindowSource) -> Int {
        window.windowDurationMins ?? (source == .primary ? 0 : Int.max)
    }

    private static func title(durationMinutes: Int?, fallbackIndex: Int?) -> String {
        guard let durationMinutes, durationMinutes > 0 else {
            return fallbackIndex.map { "官方额度 \($0)" } ?? "官方额度"
        }
        if durationMinutes == 7 * 1_440 {
            return "周额度"
        }
        if durationMinutes.isMultiple(of: 1_440) {
            return "\(durationMinutes / 1_440) 天"
        }
        if durationMinutes.isMultiple(of: 60) {
            return "\(durationMinutes / 60) 小时"
        }
        return "\(durationMinutes) 分钟"
    }

    private static func compactDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(ceil(seconds / 60)))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
