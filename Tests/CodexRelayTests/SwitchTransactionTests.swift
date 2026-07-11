import Foundation
import Testing
@testable import CodexRelay

@Test func legacyRelayStateDecodesWithoutPendingTransaction() throws {
    let data = Data(#"{"activeProfile":"a","completedRecoveryKeys":[]}"#.utf8)
    let state = try JSONDecoder().decode(RelayState.self, from: data)
    #expect(state.activeProfile == "a")
    #expect(state.pendingSwitch == nil)
}

@Test func switchCredentialBackupIsPrivateDurableAndRemovable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appendingPathComponent("codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let storage = RelayStorage(paths: RelayPaths(
        config: RelayConfig(codexHome: codexHome.path),
        rootOverride: root.appendingPathComponent("relay", isDirectory: true)))
    try storage.bootstrap()

    let id = UUID()
    let auth = Data(#"{"tokens":{"account_id":"source","access_token":"secret"}}"#.utf8)
    try storage.prepareSwitchBackup(id: id, authData: auth)

    #expect(try storage.loadSwitchBackup(id: id) == auth)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: storage.paths.switchAuthBackup(id).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    storage.removeSwitchBackup(id: id)
    #expect(!FileManager.default.fileExists(atPath: storage.paths.switchAuthBackup(id).path))
}

@Test func switchTransactionRoundTripsEveryPhase() throws {
    let snapshot = SwitchSnapshot(
        id: UUID(), createdAt: Date(timeIntervalSince1970: 123),
        sourceProfile: "a", targetProfile: "b",
        threads: [RecoveryEntry(
            threadId: "thread", cwd: "/tmp", previousStatus: "active",
            recoveryKey: "stable-key")])

    for phase in [SwitchPhase.prepared, .activated, .validated, .recovering, .completed] {
        var state = RelayState()
        state.pendingSwitch = SwitchTransaction(
            snapshot: snapshot, phase: phase,
            sourceAccountID: "account-a", targetAccountID: "account-b",
            previousLastSwitchAt: nil)
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RelayState.self, from: encoded)
        #expect(decoded.pendingSwitch?.phase == phase)
        #expect(decoded.pendingSwitch?.snapshot.threads.first?.recoveryKey == "stable-key")
    }
}
