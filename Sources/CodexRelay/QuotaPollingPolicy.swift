import Foundation

enum QuotaPollingPolicy {
    static let nearExhaustionInterval: TimeInterval = 30
    static let elevatedUsageInterval: TimeInterval = 60
    static let relaxedInterval: TimeInterval = 5 * 60
    static let standbyInterval: TimeInterval = 20 * 60
    static let genericFailureRetryInterval: TimeInterval = 5 * 60
    static let authenticationFailureThreshold = 3

    static func activeInterval(usedPercents: [Int]) -> TimeInterval {
        guard let highestUsedPercent = usedPercents.max() else {
            return nearExhaustionInterval
        }
        if highestUsedPercent >= 98 { return nearExhaustionInterval }
        if highestUsedPercent >= 90 { return elevatedUsageInterval }
        return relaxedInterval
    }

    static func authenticationRetryInterval(after failureCount: Int) -> TimeInterval {
        switch failureCount {
        case ...1: nearExhaustionInterval
        case 2: 2 * 60
        default: genericFailureRetryInterval
        }
    }

    static func activeInterval(for status: AccountQuotaStatus?) -> TimeInterval {
        guard let status else { return nearExhaustionInterval }
        if status.consecutiveAuthenticationFailures > 0 {
            return authenticationRetryInterval(
                after: status.consecutiveAuthenticationFailures)
        }
        if status.error != nil { return genericFailureRetryInterval }
        return activeInterval(usedPercents: [
            status.primary?.usedPercent,
            status.secondary?.usedPercent,
        ].compactMap { $0 })
    }

    static func standbyInterval(for status: AccountQuotaStatus?) -> TimeInterval {
        guard let status else { return 0 }
        if status.consecutiveAuthenticationFailures > 0 {
            return authenticationRetryInterval(
                after: status.consecutiveAuthenticationFailures)
        }
        if status.error != nil { return genericFailureRetryInterval }
        return standbyInterval
    }

    static func isActiveCheckDue(
        status: AccountQuotaStatus?,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let status else { return true }
        let interval = max(minimumInterval, activeInterval(for: status))
        return now.timeIntervalSince(status.lastAttemptAt) >= interval
    }

    static func isStandbyCheckDue(status: AccountQuotaStatus?, now: Date) -> Bool {
        guard let status else { return true }
        return now.timeIntervalSince(status.lastAttemptAt) >= standbyInterval(for: status)
    }
}
