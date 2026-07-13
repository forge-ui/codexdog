import Foundation

struct RelayPaths: Sendable {
    let root: URL
    let codexHome: URL

    init(config: RelayConfig, rootOverride: URL? = nil) {
        let fm = FileManager.default
        root = rootOverride ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexRelay", isDirectory: true)
        codexHome = URL(fileURLWithPath: NSString(string: config.codexHome).expandingTildeInPath, isDirectory: true)
    }

    var profiles: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    var config: URL { root.appendingPathComponent("config.json") }
    var state: URL { root.appendingPathComponent("state.json") }
    var runtime: URL { root.appendingPathComponent("runtime.json") }
    var accountQuotas: URL { root.appendingPathComponent("account-quotas.json") }
    var logs: URL { root.appendingPathComponent("relay.log") }
    func profileAuth(_ name: String) -> URL { profiles.appendingPathComponent(name).appendingPathComponent("auth.json") }
    var activeAuth: URL { codexHome.appendingPathComponent("auth.json") }
}

final class RelayStorage: @unchecked Sendable {
    private struct AuthSnapshot {
        let data: Data
        let accountID: String
    }

    let paths: RelayPaths
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(paths: RelayPaths) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func bootstrap() throws {
        try fm.createDirectory(at: paths.profiles, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: paths.config.path) { try write(RelayConfig.default, to: paths.config, permissions: 0o600) }
        if !fm.fileExists(atPath: paths.state.path) { try write(RelayState(), to: paths.state, permissions: 0o600) }
    }

    func loadConfig() throws -> RelayConfig { try read(RelayConfig.self, from: paths.config) }
    func saveConfig(_ config: RelayConfig) throws { try write(config, to: paths.config, permissions: 0o600) }
    func loadState() throws -> RelayState { try read(RelayState.self, from: paths.state) }
    func saveState(_ state: RelayState) throws { try write(state, to: paths.state, permissions: 0o600) }
    func saveRuntime(_ runtime: RelayRuntimeStatus) throws { try write(runtime, to: paths.runtime, permissions: 0o600) }

    func updateAccountQuota(_ status: AccountQuotaStatus) throws {
        var collection: AccountQuotaCollection
        if fm.fileExists(atPath: paths.accountQuotas.path) {
            collection = try read(AccountQuotaCollection.self, from: paths.accountQuotas)
        } else {
            collection = AccountQuotaCollection()
        }
        collection.accounts[status.profile] = status
        try write(collection, to: paths.accountQuotas, permissions: 0o600)
    }

    func deleteProfile(_ profile: String) throws {
        try validate(profile)
        let directory = paths.profiles.appendingPathComponent(profile, isDirectory: true)
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }

        guard fm.fileExists(atPath: paths.accountQuotas.path) else { return }
        var collection = try read(AccountQuotaCollection.self, from: paths.accountQuotas)
        collection.accounts.removeValue(forKey: profile)
        try write(collection, to: paths.accountQuotas, permissions: 0o600)
    }

    @discardableResult
    func saveCurrentAuth(as profile: String, expectedAccountID: String? = nil) throws -> Data {
        try validate(profile)
        let current = try authSnapshot(at: paths.activeAuth, label: "Current Codex auth")
        if let expectedAccountID, current.accountID != expectedAccountID {
            throw RelayError.verification(
                "Current Codex account changed before profile \(profile) could be saved")
        }
        let destination = paths.profileAuth(profile)
        if fm.fileExists(atPath: destination.path) {
            let existing = try authSnapshot(at: destination, label: "Profile \(profile) auth")
            guard existing.accountID == current.accountID else {
                throw RelayError.verification(
                    "Refusing to overwrite profile \(profile): current account \(current.accountID) does not match saved account \(existing.accountID)")
            }
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try atomicWrite(current.data, to: destination, permissions: 0o600)
        return current.data
    }

    func prepareProfileHome(_ profile: String) throws -> URL {
        try validate(profile)
        let directory = paths.profiles.appendingPathComponent(profile, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    func secureProfileAuth(_ profile: String) throws {
        try validate(profile)
        let auth = paths.profileAuth(profile)
        guard fm.fileExists(atPath: auth.path) else { throw RelayError.missingFile("Login did not create \(auth.path)") }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
    }

    func activate(profile: String) throws -> Data {
        try validate(profile)
        let source = paths.profileAuth(profile)
        guard fm.fileExists(atPath: source.path) else { throw RelayError.invalidProfile("Profile \(profile) has not been saved") }
        let target = try authSnapshot(at: source, label: "Profile \(profile) auth")
        let previous = try Data(contentsOf: paths.activeAuth)
        try atomicWrite(target.data, to: paths.activeAuth, permissions: 0o600)
        return previous
    }

    func restoreAuth(_ data: Data) throws { try atomicWrite(data, to: paths.activeAuth, permissions: 0o600) }
    func profileExists(_ profile: String) -> Bool { fm.fileExists(atPath: paths.profileAuth(profile).path) }

    func validateProfileName(_ profile: String) throws {
        try validate(profile)
    }

    func validateCurrentChatGPTAuth() throws -> String {
        let data = try Data(contentsOf: paths.activeAuth)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["auth_mode"] as? String == "chatgpt",
              let tokens = root["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw RelayError.verification(
                "Current Codex login is not a complete ChatGPT subscription credential")
        }
        return accountID
    }

    func activeAccountID() throws -> String {
        try authSnapshot(at: paths.activeAuth, label: "Current Codex auth").accountID
    }

    func profileAccountID(_ profile: String) throws -> String {
        try validate(profile)
        return try authSnapshot(at: paths.profileAuth(profile), label: "Profile \(profile) auth").accountID
    }

    @discardableResult
    func assertActiveAccount(expectedAccountID: String) throws -> String {
        let actual = try activeAccountID()
        guard actual == expectedAccountID else {
            throw RelayError.verification(
                "Activated account mismatch: expected \(expectedAccountID), found \(actual)")
        }
        return actual
    }

    @discardableResult
    func assertActiveAccount(matchesProfile profile: String) throws -> String {
        let expected = try profileAccountID(profile)
        return try assertActiveAccount(expectedAccountID: expected)
    }

    func detectActiveProfile(in profiles: [String]) -> String? {
        guard let activeID = try? activeAccountID() else { return nil }
        return profiles.first { (try? profileAccountID($0)) == activeID }
    }

    func sameAccount(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsID = try? profileAccountID(lhs),
              let rhsID = try? profileAccountID(rhs) else { return false }
        return lhsID == rhsID
    }

    func duplicateProfile(for profile: String, among profiles: [String]) -> String? {
        profiles.first { $0 != profile && sameAccount(profile, $0) }
    }

    private func validate(_ profile: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !profile.isEmpty, profile.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RelayError.invalidProfile("Profile names may contain only letters, numbers, hyphen, and underscore")
        }
    }

    private func authSnapshot(at url: URL, label: String) throws -> AuthSnapshot {
        guard fm.fileExists(atPath: url.path) else {
            throw RelayError.missingFile("Missing \(url.path)")
        }
        let data = try Data(contentsOf: url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String,
              !accountID.isEmpty else {
            throw RelayError.verification("\(label) is missing tokens.account_id")
        }
        return AuthSnapshot(data: data, accountID: accountID)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to url: URL, permissions: Int) throws {
        try atomicWrite(encoder.encode(value), to: url, permissions: permissions)
    }

    private func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: url) }
    }
}
