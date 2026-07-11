import Foundation
import AppKit
import Darwin

@MainActor
final class RelayMenuStore: ObservableObject {
    @Published var config: MenuRelayConfig?
    @Published var state: MenuRelayState?
    @Published var runtime: MenuRuntimeStatus?
    @Published var accountQuotas: [String: MenuAccountQuota] = [:]
    @Published var profileEmails: [String: String] = [:]
    @Published var isWorkerRunning = false
    @Published var message: String?
    @Published var commandOutput = ""
    @Published var commandIsRunning = false
    @Published private(set) var enrollmentAuthorizationURL: URL?
    @Published private(set) var enrollmentAuthorizationCode: String?
    @Published var localUsage: LocalUsageSnapshot?
    @Published var localUsageError: String?
    @Published var localUsageIsLoading = false

    private let supervisor = RelaySupervisor.shared
    private var timer: Timer?
    private var commandProcess: Process?
    private var rawCommandOutput = ""
    private var localUsageTask: Task<Void, Never>?
    private var lastLocalUsageRefresh: Date?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(startSupervisor: Bool = true, loadLocalUsage: Bool = true) {
        refresh()
        if loadLocalUsage {
            refreshLocalUsage(force: true)
        }
        if startSupervisor {
            do { try supervisor.start() }
            catch { message = error.localizedDescription }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .relayWorkerChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        config = decode(MenuRelayConfig.self, at: root.appendingPathComponent("config.json")) ?? config
        state = decode(MenuRelayState.self, at: root.appendingPathComponent("state.json")) ?? state
        runtime = decode(MenuRuntimeStatus.self, at: root.appendingPathComponent("runtime.json")) ?? runtime
        accountQuotas = decode(MenuAccountQuotaCollection.self, at: root.appendingPathComponent("account-quotas.json"))?.accounts ?? accountQuotas
        let resolvedEmails = Dictionary(uniqueKeysWithValues: (config?.profiles ?? []).compactMap { profile in
            AccountIdentityResolver.email(forProfile: profile, root: root).map { (profile, $0) }
        })
        if resolvedEmails != profileEmails {
            profileEmails = resolvedEmails
        }
        isWorkerRunning = supervisor.isRunning
    }

    func displayName(for profile: String) -> String {
        profileEmails[profile] ?? profile
    }

    func enrollNewAccount() {
        let generatedName = "account-" + UUID().uuidString.prefix(8).lowercased()
        runProfileCommand("login", name: generatedName)
    }

    func isProfileScheduled(_ profile: String) -> Bool {
        !(config?.disabledProfiles ?? []).contains(profile)
    }

    func setProfileScheduling(_ profile: String, enabled: Bool) {
        runProfileCommand(enabled ? "enable" : "disable", name: profile)
    }

    func deleteProfile(_ profile: String) {
        runProfileCommand("delete", name: profile)
    }

    func refreshLocalUsage(force: Bool = false) {
        if !force,
           let lastLocalUsageRefresh,
           Date().timeIntervalSince(lastLocalUsageRefresh) < 60 {
            return
        }
        guard localUsageTask == nil else { return }

        localUsageIsLoading = true
        localUsageTask = Task { [weak self] in
            defer {
                self?.localUsageIsLoading = false
                self?.localUsageTask = nil
                self?.lastLocalUsageRefresh = Date()
            }
            do {
                self?.localUsage = try await LocalUsageService.fetch()
                self?.localUsageError = nil
            } catch {
                self?.localUsageError = error.localizedDescription
            }
        }
    }

    func toggleWatchdog() {
        if supervisor.isRunning {
            supervisor.stop()
        } else {
            do { try supervisor.start(); message = nil }
            catch { message = error.localizedDescription }
        }
        refresh()
    }

    func setAutomaticSwitching(_ enabled: Bool) {
        guard let helper = supervisor.helperPath() else { message = "找不到 codex-relay helper"; return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["config", "auto-switch", enabled ? "on" : "off"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { message = "自动切换设置失败"; return }
            supervisor.stop()
            try supervisor.start()
            message = nil
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func runProfileCommand(_ action: String, name: String) {
        guard commandProcess?.isRunning != true else { return }
        guard !name.isEmpty else { message = "请输入账号名称"; return }
        guard let helper = supervisor.helperPath() else { message = "找不到 codex-relay helper"; return }

        let workerWasRunning = supervisor.isRunning
        let pausesWorker = ["disable", "enable", "delete"].contains(action)
        if pausesWorker && workerWasRunning {
            supervisor.stop()
        }

        resetCommandOutput()
        commandIsRunning = true
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["profile", action, name]
        if action == "login" {
            process.arguments?.append(contentsOf: ["--parent-pid", String(getpid())])
        }
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendCommandOutput(text) }
        }
        process.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self?.commandIsRunning = false
                self?.commandProcess = nil
                if workerWasRunning && (pausesWorker || (process.terminationStatus == 0 && action == "login")) {
                    self?.supervisor.stop()
                    do { try self?.supervisor.start() }
                    catch { self?.message = error.localizedDescription }
                }
                self?.refresh()
                if process.terminationStatus != 0 {
                    self?.message = "账号操作失败"
                } else if action != "login" {
                    self?.message = nil
                }
            }
        }
        do {
            try process.run()
            commandProcess = process
        } catch {
            commandIsRunning = false
            if pausesWorker && workerWasRunning {
                try? supervisor.start()
            }
            message = error.localizedDescription
        }
    }

    func openDeviceLogin() {
        let fallback = URL(string: "https://auth.openai.com/codex/device")!
        NSWorkspace.shared.open(enrollmentAuthorizationURL ?? fallback)
    }

    func copyEnrollmentAuthorizationCode() {
        guard let enrollmentAuthorizationCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(enrollmentAuthorizationCode, forType: .string)
    }

    func quit() {
        shutdown()
        NSApplication.shared.terminate(nil)
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        localUsageTask?.cancel()
        localUsageTask = nil
        LocalUsageProcessRegistry.shared.stop()
        terminateCommandProcessTree()
        supervisor.stop()
    }

    var primaryRemaining: Int? { runtime?.primaryUsedPercent.map { max(0, 100 - $0) } }
    var secondaryRemaining: Int? { runtime?.secondaryUsedPercent.map { max(0, 100 - $0) } }
    var automaticSwitchingEnabled: Bool { !(config?.dryRun ?? true) }

    private var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexRelay", isDirectory: true)
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func resetCommandOutput() {
        rawCommandOutput = ""
        commandOutput = ""
        enrollmentAuthorizationURL = nil
        enrollmentAuthorizationCode = nil
    }

    private func appendCommandOutput(_ text: String) {
        rawCommandOutput.append(text)
        let parsed = EnrollmentOutputParser.parse(rawCommandOutput)
        commandOutput = parsed.cleanOutput
        enrollmentAuthorizationURL = parsed.authorizationURL
        enrollmentAuthorizationCode = parsed.authorizationCode
    }

    private func terminateCommandProcessTree() {
        guard let process = commandProcess, process.isRunning else {
            commandProcess = nil
            return
        }

        let descendants = descendantPIDs(of: process.processIdentifier)
        descendants.reversed().forEach { Darwin.kill($0, SIGTERM) }
        Darwin.kill(-process.processIdentifier, SIGTERM)
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        descendants.reversed().forEach { Darwin.kill($0, SIGKILL) }
        Darwin.kill(-process.processIdentifier, SIGKILL)
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        commandProcess = nil
        commandIsRunning = false
    }

    private func descendantPIDs(of parentPID: pid_t) -> [pid_t] {
        let query = Process()
        let output = Pipe()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        query.arguments = ["-P", String(parentPID)]
        query.standardOutput = output
        query.standardError = FileHandle.nullDevice
        guard (try? query.run()) != nil else { return [] }
        query.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let children = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) } ?? []
        return children + children.flatMap { descendantPIDs(of: $0) }
    }
}
