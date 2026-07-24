import Foundation
import Testing
@testable import CodexRelay

@Test func activeQuotaPollingAdaptsToTheMostConstrainedOfficialWindow() {
    #expect(QuotaPollingPolicy.activeInterval(usedPercents: [89]) == 300)
    #expect(QuotaPollingPolicy.activeInterval(usedPercents: [90]) == 60)
    #expect(QuotaPollingPolicy.activeInterval(usedPercents: [97]) == 60)
    #expect(QuotaPollingPolicy.activeInterval(usedPercents: [98]) == 30)
    #expect(QuotaPollingPolicy.activeInterval(usedPercents: [20, 99]) == 30)
    #expect(QuotaPollingPolicy.activeInterval(usedPercents: []) == 30)
}

@Test func authenticationFailuresUseProgressiveRetryDelays() {
    #expect(QuotaPollingPolicy.authenticationRetryInterval(after: 1) == 30)
    #expect(QuotaPollingPolicy.authenticationRetryInterval(after: 2) == 120)
    #expect(QuotaPollingPolicy.authenticationRetryInterval(after: 3) == 300)
    #expect(QuotaPollingPolicy.authenticationRetryInterval(after: 8) == 300)
}

@Test func legacyAccountQuotaStatusDecodesWithSafePollingDefaults() throws {
    let data = Data(
        #"""
        {
          "profile": "legacy",
          "updatedAt": "2026-07-24T00:00:00Z",
          "primary": {"usedPercent": 12},
          "planType": "pro"
        }
        """#.utf8
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let status = try decoder.decode(AccountQuotaStatus.self, from: data)

    #expect(status.lastAttemptAt == status.updatedAt)
    #expect(status.consecutiveAuthenticationFailures == 0)
}
