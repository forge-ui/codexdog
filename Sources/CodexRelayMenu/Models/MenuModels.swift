import Foundation

struct MenuRelayConfig: Decodable {
    var profiles: [String]
    var disabledProfiles: [String]?
    var thresholdUsedPercent: Int
    var pollIntervalSeconds: Int
    var dryRun: Bool
}

struct MenuRelayState: Decodable {
    var activeProfile: String?
    var lastSwitchAt: Date?
    var lastError: String?
}

struct MenuRuntimeStatus: Decodable {
    var updatedAt: Date
    var activeProfile: String?
    var primaryUsedPercent: Int?
    var secondaryUsedPercent: Int?
    var planType: String?
    var message: String
}

struct MenuQuotaWindow: Decodable {
    var usedPercent: Int
    var resetsAt: Int64?
    var windowDurationMins: Int?
}

struct MenuAccountQuota: Decodable {
    var profile: String
    var updatedAt: Date
    var primary: MenuQuotaWindow?
    var secondary: MenuQuotaWindow?
    var planType: String?
    var error: String?
    var duplicateOf: String?
    var lastAttemptAt: Date? = nil
    var consecutiveAuthenticationFailures: Int? = nil
}

struct MenuAccountQuotaCollection: Decodable {
    var accounts: [String: MenuAccountQuota]
}

struct LocalUsageSnapshot: Decodable, Sendable {
    var provider: String
    var source: String
    var updatedAt: String
    var sessionCostUSD: Double?
    var sessionTokens: Int64?
    var last30DaysCostUSD: Double?
    var last30DaysTokens: Int64?
    var daily: [LocalUsageDay]

    var mostUsedModel: String? {
        var totals: [String: Int64] = [:]
        for day in daily {
            for breakdown in day.modelBreakdowns {
                totals[breakdown.modelName, default: 0] += breakdown.totalTokens
            }
        }
        return totals.max(by: { $0.value < $1.value })?.key
    }
}

struct LocalUsageDay: Decodable, Sendable, Identifiable {
    var date: String
    var totalTokens: Int64
    var totalCost: Double
    var modelBreakdowns: [LocalUsageModelBreakdown]

    var id: String { date }
}

struct LocalUsageModelBreakdown: Decodable, Sendable {
    var modelName: String
    var totalTokens: Int64
}
