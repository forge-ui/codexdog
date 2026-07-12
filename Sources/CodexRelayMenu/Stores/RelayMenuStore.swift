import Foundation
import AppKit
import Darwin

enum MenuRefreshPhase: Equatable {
    case idle
    case refreshing
    case succeeded
    case failed
}

enum AccountEnrollmentFeedback: Equatable {
    case success(String)
    case failure(String)
}

typealias LocalUsageFetcher = @Sendable () async throws -> LocalUsageSnapshot
typealias OfficialQuotaRefresher = @Sendable (_ profileCount: Int) async throws -> Void

struct MenuRefreshTiming: Sendable {
    let minimumVisibleDuration: Duration
    let resultVisibleDuration: Duration

    static let standard = MenuRefreshTiming(
        minimumVisibleDuration: .milliseconds(650),
        resultVisibleDuration: .milliseconds(900)
    )
}

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
    @Published private(set) var activeProfileCommand: String?
    @Published private(set) var accountEnrollmentFeedback: AccountEnrollmentFeedback?
    @Published private(set) var enrollmentAuthorizationURL: URL?
    @Published private(set) var enrollmentAuthorizationCode: String?
    @Published var localUsage: LocalUsageSnapshot?
    @Published var localUsageError: String?
    @Published var localUsageIsLoading = false
    @Published private(set) var refreshPhase: MenuRefreshPhase = .idle

    private let supervisor = RelaySupervisor.shared
    private let rootURL: URL
    private let localUsageFetcher: LocalUsageFetcher
    private let officialQuotaRefresher: OfficialQuotaRefresher
    private let refreshTiming: MenuRefreshTiming
    private var timer: Timer?
    private var commandProcess: Process?
    private var rawCommandOutput = ""
    private var localUsageTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastLocalUsageRefresh: Date?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        startSupervisor: Bool = true,
        loadLocalUsage: Bool = true,
        startPolling: Bool = true,
        rootURL: URL? = nil,
        refreshTiming: MenuRefreshTiming = .standard,
        localUsageFetcher: @escaping LocalUsageFetcher = { try await LocalUsageService.fetch() },
        officialQuotaRefresher: @escaping OfficialQuotaRefresher = { profileCount in
            try await RelayQuotaRefreshService.refresh(profileCount: profileCount)
        }
    ) {
        self.rootURL = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexRelay", isDirectory: true)
        self.refreshTiming = refreshTiming
        self.localUsageFetcher = localUsageFetcher
        self.officialQuotaRefresher = officialQuotaRefresher
        refresh()
        if loadLocalUsage {
            refreshLocalUsage(force: true)
        }
        if startSupervisor {
            do { try supervisor.start() }
            catch { message = error.localizedDescription }
        }
        refresh()
        if startPolling {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            NotificationCenter.default.addObserver(
                forName: .relayWorkerChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
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

    var isRefreshBusy: Bool { refreshPhase != .idle }
    var visibleErrors: [String] {
        var errors: [String] = []
        if let stateError = state?.lastError, !stateError.isEmpty {
            errors.append(stateError)
        }
        if let message, !message.isEmpty, !errors.contains(message) {
            errors.append(message)
        }
        return errors
    }

    func manualRefresh() {
        guard refreshTask == nil, !commandIsRunning else { return }

        message = nil
        localUsageError = nil
        refreshPhase = .refreshing
        refresh()
        refreshLocalUsage(force: true)

        let quotaRefresher = officialQuotaRefresher
        let profileCount = config?.profiles.count ?? 0
        let timing = refreshTiming
        refreshTask = Task { [weak self] in
            let minimumDelay = Task {
                try? await Task.sleep(for: timing.minimumVisibleDuration)
            }
            let refreshError: String?
            do {
                try await quotaRefresher(profileCount)
                refreshError = nil
            } catch is CancellationError {
                refreshError = nil
            } catch {
                refreshError = error.localizedDescription
            }
            await minimumDelay.value

            guard let self else { return }
            while self.localUsageTask != nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else {
                self.refreshPhase = .idle
                self.refreshTask = nil
                return
            }

            self.refresh()
            let localRefreshError = self.localUsageError
            if let refreshError, !refreshError.isEmpty {
                self.refreshPhase = .failed
                self.message = "刷新失败：\(self.compactMessage(refreshError))"
            } else if let localRefreshError, !localRefreshError.isEmpty {
                self.refreshPhase = .failed
                self.message = "本机用量刷新失败：\(self.compactMessage(localRefreshError))"
            } else {
                self.refreshPhase = .succeeded
                self.message = nil
            }

            try? await Task.sleep(for: timing.resultVisibleDuration)
            guard !Task.isCancelled else {
                self.refreshPhase = .idle
                self.refreshTask = nil
                return
            }
            self.refreshPhase = .idle
            self.refreshTask = nil
        }
    }

    func enrollNewAccount() {
        let generatedName = "account-" + UUID().uuidString.prefix(8).lowercased()
        runProfileCommand("login", name: generatedName)
    }

    func importCurrentAccount() {
        let generatedName = "account-" + UUID().uuidString.prefix(8).lowercased()
        runProfileCommand("import-current", name: generatedName)
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
        let fetcher = localUsageFetcher
        localUsageTask = Task { [weak self] in
            defer {
                self?.localUsageIsLoading = false
                self?.localUsageTask = nil
                self?.lastLocalUsageRefresh = Date()
            }
            do {
                self?.localUsage = try await fetcher()
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
        guard !isRefreshBusy, !commandIsRunning else { return }
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
        guard !isRefreshBusy else { return }
        guard commandProcess?.isRunning != true else { return }
        guard !name.isEmpty else { message = "请输入账号名称"; return }
        guard let helper = supervisor.helperPath() else { message = "找不到 codex-relay helper"; return }

        message = nil
        let workerWasRunning = supervisor.isRunning
        let pausesWorker = ["disable", "enable", "delete"].contains(action)
        if pausesWorker && workerWasRunning {
            supervisor.stop()
        }

        resetCommandOutput()
        commandIsRunning = true
        activeProfileCommand = action
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
                self?.activeProfileCommand = nil
                var restartError: String?
                let reloadsWorker = process.terminationStatus == 0
                    && ["login", "import-current"].contains(action)
                if workerWasRunning && (pausesWorker || reloadsWorker) {
                    self?.supervisor.stop()
                    do { try self?.supervisor.start() }
                    catch { restartError = error.localizedDescription }
                }
                self?.refresh()
                if let self {
                    let completionMessage = ProfileCommandCompletionPolicy.message(
                        terminationStatus: process.terminationStatus,
                        restartError: restartError,
                        commandOutput: self.commandOutput
                    )
                    self.message = completionMessage
                    if ["login", "import-current"].contains(action) {
                        if process.terminationStatus == 0, completionMessage == nil {
                            self.accountEnrollmentFeedback = .success(
                                action == "import-current"
                                    ? "当前账号已同步到 CodexDog"
                                    : "其他账号已添加"
                            )
                        } else {
                            self.accountEnrollmentFeedback = .failure(
                                completionMessage ?? "账号添加失败"
                            )
                        }
                    }
                }
            }
        }
        do {
            try process.run()
            commandProcess = process
        } catch {
            commandIsRunning = false
            activeProfileCommand = nil
            if pausesWorker && workerWasRunning {
                try? supervisor.start()
            }
            message = error.localizedDescription
            if ["login", "import-current"].contains(action) {
                accountEnrollmentFeedback = .failure(error.localizedDescription)
            }
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
        refreshTask?.cancel()
        refreshTask = nil
        refreshPhase = .idle
        localUsageTask?.cancel()
        localUsageTask = nil
        LocalUsageProcessRegistry.shared.stop()
        RelayQuotaRefreshProcessRegistry.shared.stop()
        terminateCommandProcessTree()
        supervisor.stop()
    }

    var primaryRemaining: Int? { runtime?.primaryUsedPercent.map { max(0, 100 - $0) } }
    var secondaryRemaining: Int? { runtime?.secondaryUsedPercent.map { max(0, 100 - $0) } }
    var automaticSwitchingEnabled: Bool { !(config?.dryRun ?? true) }

    private var root: URL { rootURL }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func resetCommandOutput() {
        rawCommandOutput = ""
        commandOutput = ""
        accountEnrollmentFeedback = nil
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

    private func compactMessage(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).last.map(String.init) ?? message
        return String(line.replacingOccurrences(of: "codex-relay: ", with: "").prefix(160))
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
        activeProfileCommand = nil
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
