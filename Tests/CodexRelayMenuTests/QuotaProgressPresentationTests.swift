import Testing
@testable import CodexRelayMenu

@Test func onlyTheCurrentHealthyAccountUsesTheActiveTone() {
    #expect(QuotaProgressPresentation.tone(remaining: 100, isActive: true) == .active)
    #expect(QuotaProgressPresentation.tone(remaining: 100, isActive: false) == .neutral)
}

@Test func lowQuotaTonesOverrideAccountActivity() {
    #expect(QuotaProgressPresentation.tone(remaining: 20, isActive: true) == .warning)
    #expect(QuotaProgressPresentation.tone(remaining: 20, isActive: false) == .warning)
    #expect(QuotaProgressPresentation.tone(remaining: 1, isActive: true) == .critical)
    #expect(QuotaProgressPresentation.tone(remaining: 1, isActive: false) == .critical)
}
