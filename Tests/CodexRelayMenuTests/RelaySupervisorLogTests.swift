import Foundation
import Testing
@testable import CodexRelayMenu

@Test func supervisorCreatesAPrivateLogFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let logURL = root.appendingPathComponent("Logs/CodexRelay/worker.log")

    let handle = try RelaySupervisor.prepareLogFile(at: logURL)
    try handle.close()

    let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
    let permissions = attributes[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}
