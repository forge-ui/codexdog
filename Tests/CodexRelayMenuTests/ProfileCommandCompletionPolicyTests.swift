import Testing
@testable import CodexRelayMenu

@Test func successfulLoginClearsAnEarlierAccountOperationFailure() {
    let message = ProfileCommandCompletionPolicy.message(
        terminationStatus: 0,
        restartError: nil,
        commandOutput: "Logged in test profile"
    )

    #expect(message == nil)
}

@Test func successfulAccountOperationPreservesAWatchdogRestartFailure() {
    let message = ProfileCommandCompletionPolicy.message(
        terminationStatus: 0,
        restartError: "看门狗无法启动",
        commandOutput: "Deleted test profile"
    )

    #expect(message == "看门狗无法启动")
}

@Test func failedAccountOperationUsesTheSpecificCommandError() {
    let message = ProfileCommandCompletionPolicy.message(
        terminationStatus: 1,
        restartError: nil,
        commandOutput: "codex-relay: Profile test-profile already exists"
    )

    #expect(message == "账号操作失败：Profile test-profile already exists")
}
