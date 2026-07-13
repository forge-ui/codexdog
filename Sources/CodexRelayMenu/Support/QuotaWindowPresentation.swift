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

    private static func sortValue(_ window: MenuQuotaWindow, source: QuotaWindowSource) -> Int {
        window.windowDurationMins ?? (source == .primary ? 0 : Int.max)
    }

    private static func title(durationMinutes: Int?, fallbackIndex: Int?) -> String {
        guard let durationMinutes, durationMinutes > 0 else {
            return fallbackIndex.map { "官方额度 \($0)" } ?? "官方额度"
        }
        if durationMinutes.isMultiple(of: 1_440) {
            return "\(durationMinutes / 1_440) 天"
        }
        if durationMinutes.isMultiple(of: 60) {
            return "\(durationMinutes / 60) 小时"
        }
        return "\(durationMinutes) 分钟"
    }
}
