import Foundation
import Testing
@testable import CodexRelayMenu

@Test func weeklyOnlyOfficialWindowIsPresentedAsSevenDays() {
    let quota = MenuAccountQuota(
        profile: "account-a",
        updatedAt: Date(),
        primary: MenuQuotaWindow(
            usedPercent: 12,
            resetsAt: nil,
            windowDurationMins: 10_080
        ),
        secondary: nil,
        planType: "pro",
        error: nil,
        duplicateOf: nil
    )

    let rows = QuotaWindowPresentation.rows(for: quota)

    #expect(rows.count == 1)
    #expect(rows.first?.title == "7 天")
    #expect(rows.first?.source == .primary)
}

@Test func officialWindowsAreNamedAndSortedByDurationInsteadOfFieldName() {
    let quota = MenuAccountQuota(
        profile: "account-a",
        updatedAt: Date(),
        primary: MenuQuotaWindow(
            usedPercent: 20,
            resetsAt: nil,
            windowDurationMins: 10_080
        ),
        secondary: MenuQuotaWindow(
            usedPercent: 10,
            resetsAt: nil,
            windowDurationMins: 300
        ),
        planType: "pro",
        error: nil,
        duplicateOf: nil
    )

    let rows = QuotaWindowPresentation.rows(for: quota)

    #expect(rows.map(\.title) == ["5 小时", "7 天"])
    #expect(rows.map(\.source) == [.secondary, .primary])
}

@Test func missingOfficialDurationDoesNotGuessAWindowTypeFromTheFieldName() {
    let quota = MenuAccountQuota(
        profile: "account-a",
        updatedAt: Date(),
        primary: MenuQuotaWindow(
            usedPercent: 20,
            resetsAt: nil,
            windowDurationMins: nil
        ),
        secondary: nil,
        planType: "pro",
        error: nil,
        duplicateOf: nil
    )

    let rows = QuotaWindowPresentation.rows(for: quota)

    #expect(rows.map(\.title) == ["官方额度"])
}

@Test func pacePredictsExhaustionBeforeTheWindowResets() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let window = MenuQuotaWindow(
        usedPercent: 20,
        resetsAt: Int64(now.addingTimeInterval(260 * 60).timeIntervalSince1970),
        windowDurationMins: 300
    )

    #expect(
        QuotaWindowPresentation.paceDescription(for: window, sampledAt: now, now: now)
            == "预计 2h 40m 后耗尽"
    )
}

@Test func paceSaysTheQuotaWillLastWhenProjectedExhaustionIsAfterReset() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let window = MenuQuotaWindow(
        usedPercent: 5,
        resetsAt: Int64(now.addingTimeInterval(6 * 24 * 60 * 60).timeIntervalSince1970),
        windowDurationMins: 7 * 24 * 60
    )

    #expect(
        QuotaWindowPresentation.paceDescription(for: window, sampledAt: now, now: now)
            == "预计可支撑至重置"
    )
}

@Test func paceWaitsForEnoughWindowHistoryBeforeEstimating() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let window = MenuQuotaWindow(
        usedPercent: 20,
        resetsAt: Int64(now.addingTimeInterval(295 * 60).timeIntervalSince1970),
        windowDurationMins: 300
    )

    #expect(QuotaWindowPresentation.paceDescription(for: window, sampledAt: now, now: now) == nil)
}

@Test func paceDoesNotGuessWithoutWindowMetadata() {
    let window = MenuQuotaWindow(
        usedPercent: 20,
        resetsAt: nil,
        windowDurationMins: 300
    )

    #expect(QuotaWindowPresentation.paceDescription(for: window, sampledAt: Date()) == nil)
}

@Test func paceCountdownUsesTheOriginalSampleInsteadOfMakingStaleUsageLookSlower() {
    let sampledAt = Date(timeIntervalSince1970: 2_000_000_000)
    let window = MenuQuotaWindow(
        usedPercent: 20,
        resetsAt: Int64(sampledAt.addingTimeInterval(260 * 60).timeIntervalSince1970),
        windowDurationMins: 300
    )

    let tenMinutesLater = sampledAt.addingTimeInterval(10 * 60)

    #expect(
        QuotaWindowPresentation.paceDescription(
            for: window,
            sampledAt: sampledAt,
            now: tenMinutesLater
        ) == "预计 2h 30m 后耗尽"
    )
}
