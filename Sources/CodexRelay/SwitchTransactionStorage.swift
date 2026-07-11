import Foundation

extension RelayPaths {
    var switchTransactions: URL { root.appendingPathComponent("switch-transactions", isDirectory: true) }

    func switchAuthBackup(_ id: UUID) -> URL {
        switchTransactions
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("source-auth.json")
    }
}

extension RelayStorage {
    func prepareSwitchBackup(id: UUID, authData: Data) throws {
        let destination = paths.switchAuthBackup(id)
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".source-auth.\(UUID().uuidString).tmp")
        try authData.write(to: temporary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    func loadSwitchBackup(id: UUID) throws -> Data {
        let url = paths.switchAuthBackup(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RelayError.missingFile("Missing switch credential backup for \(id.uuidString.lowercased())")
        }
        return try Data(contentsOf: url)
    }

    func removeSwitchBackup(id: UUID) {
        let directory = paths.switchAuthBackup(id).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }
}
