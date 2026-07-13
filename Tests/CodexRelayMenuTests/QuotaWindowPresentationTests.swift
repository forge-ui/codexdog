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
