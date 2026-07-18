import Foundation
import Testing
@testable import CodexRelay

@Test func recoveryWakeMessageKeepsOnlyOneVisibleInstruction() {
    let message = AppServerClient.recoveryMessage(recoveryKey: "recovery-test-key")

    #expect(message == "请按原计划继续未完成的任务。\n<!-- codex-relay-recovery:recovery-test-key -->")
    #expect(message.contains("recovery-test-key"))
    #expect(!message.contains("previous account"))
    #expect(!message.contains("persisted thread state"))
}

@Test func recoveryMarkerStatusPrefersCompletedAcrossDuplicateMatchingTurns() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fakeCodex = root.appendingPathComponent("fake-codex")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
          ;;
        *'thread'*'read'*)
          printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"thread":{"turns":[{"status":"completed","items":[{"type":"userMessage","content":[{"type":"text","text":"<!-- codex-relay-recovery:recovery-test-key -->"}]}]},{"status":"interrupted","items":[{"type":"userMessage","content":[{"type":"text","text":"<!-- codex-relay-recovery:recovery-test-key -->"}]}]}]}}}'
          ;;
      esac
    done
    """#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

    let client = try AppServerClient(binaryPath: fakeCodex.path, codexHome: root)
    defer { client.stop() }
    let entry = RecoveryEntry(
        threadId: "recovery-test-thread", cwd: nil, previousStatus: "active",
        recoveryKey: "recovery-test-key"
    )

    #expect(try client.recoveryMarkerStatus(entry) == .completed)
}

@Test func recoveryHostRechecksMarkerAfterUnrelatedTurnCompletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fakeCodex = root.appendingPathComponent("fake-codex")
    let script = #"""
    #!/bin/sh
    reads=0
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
          ;;
        *'thread'*'read'*)
          reads=$((reads + 1))
          id=$((reads + 1))
          if [ "$reads" -eq 1 ]; then
            status='inProgress'
          else
            status='interrupted'
          fi
          printf '{"jsonrpc":"2.0","id":%s,"result":{"thread":{"turns":[{"status":"%s","items":[{"type":"userMessage","content":[{"type":"text","text":"recovery-test-key"}]}]}]}}}\n' "$id" "$status"
          if [ "$reads" -eq 1 ]; then
            printf '%s\n' '{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"recovery-test-thread","turn":{"status":"completed","items":[{"type":"userMessage","content":[{"type":"text","text":"some-unrelated-turn"}]}]}}}'
          fi
          ;;
      esac
    done
    """#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

    let client = try AppServerClient(binaryPath: fakeCodex.path, codexHome: root)
    defer { client.stop() }
    let entry = RecoveryEntry(
        threadId: "recovery-test-thread", cwd: nil, previousStatus: "active",
        recoveryKey: "recovery-test-key"
    )

    #expect(client.waitForTurns([entry], timeoutSeconds: 5).isEmpty)
}

@Test func recoveryHostStopsAfterMarkerAbsenceGracePeriod() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fakeCodex = root.appendingPathComponent("fake-codex")
    let script = #"""
    #!/bin/sh
    reads=0
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
          ;;
        *'thread'*'read'*)
          reads=$((reads + 1))
          id=$((reads + 1))
          printf '{"jsonrpc":"2.0","id":%s,"result":{"thread":{"turns":[]}}}\n' "$id"
          ;;
      esac
    done
    """#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

    let client = try AppServerClient(binaryPath: fakeCodex.path, codexHome: root)
    defer { client.stop() }
    let entry = RecoveryEntry(
        threadId: "recovery-test-thread", cwd: nil, previousStatus: "active",
        recoveryKey: "recovery-test-key"
    )
    let startedAt = Date()

    #expect(client.waitForTurns([entry], timeoutSeconds: 5).isEmpty)
    #expect(Date().timeIntervalSince(startedAt) < 4)
}

@Test func recoveryHostStopsAfterUnknownMarkerGracePeriod() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fakeCodex = root.appendingPathComponent("fake-codex")
    let script = #"""
    #!/bin/sh
    reads=0
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
          ;;
        *'thread'*'read'*)
          reads=$((reads + 1))
          id=$((reads + 1))
          printf '{"jsonrpc":"2.0","id":%s,"result":{"thread":{"turns":[{"status":"mystery","items":[{"type":"userMessage","content":[{"type":"text","text":"recovery-test-key"}]}]}]}}}\n' "$id"
          ;;
      esac
    done
    """#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

    let client = try AppServerClient(binaryPath: fakeCodex.path, codexHome: root)
    defer { client.stop() }
    let entry = RecoveryEntry(
        threadId: "recovery-test-thread", cwd: nil, previousStatus: "active",
        recoveryKey: "recovery-test-key"
    )
    let startedAt = Date()

    #expect(client.waitForTurns([entry], timeoutSeconds: 5).isEmpty)
    #expect(Date().timeIntervalSince(startedAt) < 4)
}

@Test func recoveryHostStopsAfterMarkerReadErrorGracePeriod() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fakeCodex = root.appendingPathComponent("fake-codex")
    let script = #"""
    #!/bin/sh
    reads=0
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
          ;;
        *'thread'*'read'*)
          reads=$((reads + 1))
          id=$((reads + 1))
          printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"temporary read failure"}}\n' "$id"
          ;;
      esac
    done
    """#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

    let client = try AppServerClient(binaryPath: fakeCodex.path, codexHome: root)
    defer { client.stop() }
    let entry = RecoveryEntry(
        threadId: "recovery-test-thread", cwd: nil, previousStatus: "active",
        recoveryKey: "recovery-test-key"
    )
    let startedAt = Date()

    #expect(client.waitForTurns([entry], timeoutSeconds: 5).isEmpty)
    #expect(Date().timeIntervalSince(startedAt) < 4)
}

@Test func recoveryHostStopsWaitingWhenTheSubmittedTurnIsInterrupted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fakeCodex = root.appendingPathComponent("fake-codex")
    let script = #"""
    #!/bin/sh
    reads=0
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
          ;;
        *'thread'*'read'*)
          reads=$((reads + 1))
          id=$((reads + 1))
          if [ "$reads" -eq 1 ]; then status='inProgress'; else status='interrupted'; fi
          printf '{"jsonrpc":"2.0","id":%s,"result":{"thread":{"turns":[{"status":"%s","items":[{"type":"userMessage","content":[{"type":"text","text":"recovery-test-key"}]}]}]}}}\n' "$id" "$status"
          ;;
      esac
    done
    """#
    try Data(script.utf8).write(to: fakeCodex)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fakeCodex.path)

    let client = try AppServerClient(binaryPath: fakeCodex.path, codexHome: root)
    defer { client.stop() }
    let entry = RecoveryEntry(
        threadId: "recovery-test-thread", cwd: nil, previousStatus: "active",
        recoveryKey: "recovery-test-key"
    )
    let startedAt = Date()

    let completed = client.waitForTurns([entry], timeoutSeconds: 5)

    #expect(completed.isEmpty)
    #expect(Date().timeIntervalSince(startedAt) < 4)
}
