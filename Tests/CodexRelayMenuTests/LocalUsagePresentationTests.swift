import Foundation
import Testing
@testable import CodexRelayMenu

@Test func localUsageStatisticsTimeUsesTheRequestedTimeZone() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))

    let text = LocalUsagePresentation.statisticsTime(
        "2026-07-14T14:08:55Z",
        timeZone: timeZone
    )

    #expect(text == "2026-07-14 22:08")
}

@Test func localUsageStatisticsTimeAcceptsFractionalSeconds() throws {
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let text = LocalUsagePresentation.statisticsTime(
        "2026-07-14T14:08:55.321Z",
        timeZone: timeZone
    )

    #expect(text == "2026-07-14 14:08")
}

@Test func invalidLocalUsageStatisticsTimeFallsBackToPlaceholder() {
    #expect(LocalUsagePresentation.statisticsTime("not-a-date") == "—")
}

@Test func localUsageTokenCountsUseTheSameCompactFormatEverywhere() {
    #expect(LocalUsagePresentation.compactTokens(nil) == "—")
    #expect(LocalUsagePresentation.compactTokens(999) == "999")
    #expect(LocalUsagePresentation.compactTokens(1_250) == "1K")
    #expect(LocalUsagePresentation.compactTokens(15_600_000) == "16M")
    #expect(LocalUsagePresentation.compactTokens(1_850_000_000) == "1.9B")
}
