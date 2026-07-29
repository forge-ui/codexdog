import Foundation
import AppKit
import Darwin

protocol AppServerServing: AnyObject, Sendable {
    func stop(timeout: TimeInterval)
    func rateLimits() throws -> RateLimitSnapshot
    func listThreads(limit: Int) throws -> [ThreadRecord]
    func unfinishedThreads(from threads: [ThreadRecord], recentHours: Int, now: Date) -> [ThreadRecord]
    func recoveryMarkerStatus(_ entry: RecoveryEntry) throws -> RecoveryMarkerStatus
    func resumeAndWake(_ entry: RecoveryEntry) throws
    func waitForTurns(_ entries: [RecoveryEntry], timeoutSeconds: Int) -> Set<String>
}

extension AppServerServing {
    func stop() { stop(timeout: 2) }
    func unfinishedThreads(from threads: [ThreadRecord], recentHours: Int) -> [ThreadRecord] {
        unfinishedThreads(from: threads, recentHours: recentHours, now: Date())
    }
}

extension AppServerClient: AppServerServing {}

protocol ChatGPTControlling: AnyObject {
    func quit() throws
    func openIfNeeded(path: String) throws
}

struct ProfileRotation {
    static func candidates(profiles: [String], current: String) -> [String] {
        guard !profiles.isEmpty else { return [] }
        guard let currentIndex = profiles.firstIndex(of: current) else { return profiles }
        guard profiles.count > 1 else { return [] }
        return (1..<profiles.count).map { profiles[(currentIndex + $0) % profiles.count] }
    }
}

struct RecoverySelector {
    static func select(_ threads: [ThreadRecord], now: Date, recentHours: Int, maxCount: Int, completedKeys: Set<String>, switchID: UUID) -> [RecoveryEntry] {
        let cutoff = Int64(now.addingTimeInterval(TimeInterval(-recentHours * 3600)).timeIntervalSince1970)
        return threads.filter { thread in
            thread.status == "active" || thread.status == "systemError" || (thread.updatedAt ?? 0) >= cutoff
        }.prefix(maxCount).compactMap { thread in
            let key = "codex-relay-\(switchID.uuidString.lowercased())-\(thread.id)"
            guard !completedKeys.contains(key) else { return nil }
            return RecoveryEntry(threadId: thread.id, cwd: thread.cwd, previousStatus: thread.status, recoveryKey: key)
        }
    }
}

final class ChatGPTController: ChatGPTControlling, @unchecked Sendable {
    func quit() throws {
        let bundleIdentifier = "com.openai.codex"
        let timeout: TimeInterval = 15
        let gracefulDeadline = Date().addingTimeInterval(timeout * 0.7)
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).forEach { $0.terminate() }
        while Date() < gracefulDeadline {
            if !isRunning(bundleIdentifier: bundleIdentifier) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).forEach { $0.forceTerminate() }
        let forcedDeadline = Date().addingTimeInterval(timeout * 0.3)
        while Date() < forcedDeadline {
            if !isRunning(bundleIdentifier: bundleIdentifier) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw RelayError.process("ChatGPT did not quit within \(Int(timeout)) seconds")
    }

    func open(path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RelayError.process("Failed to open \(path)") }
    }

    func openIfNeeded(path: String) throws {
        let bundleIdentifier = "com.openai.codex"
        guard !isRunning(bundleIdentifier: bundleIdentifier) else { return }
        try open(path: path)
    }

    private func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

final class RelayEngine: @unchecked Sendable {
    let storage: RelayStorage
    let config: RelayConfig
    let appController: any ChatGPTControlling
    private let appServerFactory: (URL) throws -> any AppServerServing
    private let recoveryHostsLock = NSLock()
    private var recoveryHosts: [UUID: any AppServerServing] = [:]

    init(
        storage: RelayStorage,
        config: RelayConfig,
        appController: any ChatGPTControlling = ChatGPTController(),
        appServerFactory: ((URL) throws -> any AppServerServing)? = nil)
    {
        self.storage = storage
        self.config = config
        self.appController = appController
        self.appServerFactory = appServerFactory ?? { codexHome in
            try AppServerClient(binaryPath: config.codexBinaryPath, codexHome: codexHome)
        }
    }

    private func makeAppServer(codexHome: URL) throws -> any AppServerServing {
        try appServerFactory(codexHome)
    }

    deinit {
        stopRecoveryHosts()
    }

    func diagnose() throws -> String {
        let server = try makeAppServer(codexHome: storage.paths.codexHome)
        defer { server.stop() }
        fputs("diagnose: rate limits\n", stderr)
        let limits = try server.rateLimits()
        if let active = storage.detectActiveProfile(in: config.profiles) {
            try storage.saveCurrentAuth(as: active)
        }
        fputs("diagnose: thread list\n", stderr)
        let listed = try server.listThreads(limit: max(config.maxThreadsToWake * 2, 20))
        fputs("diagnose: unfinished classification\n", stderr)
        let unfinished = server.unfinishedThreads(from: listed, recentHours: config.recoveryRecentHours)
        return "app-server=ok plan=\(limits.planType ?? "unknown") primary=\(limits.primary?.usedPercent.description ?? "n/a") secondary=\(limits.secondary?.usedPercent.description ?? "n/a") listedThreads=\(listed.count) recoverableThreads=\(unfinished.count)"
    }

    func importCurrentProfile(as requestedProfile: String) throws -> String {
        try storage.validateProfileName(requestedProfile)
        var state = try storage.loadState()
        guard state.pendingSwitch == nil else {
            throw RelayError.verification(
                "An account switch is being recovered. Wait for the watchdog to finish before importing.")
        }

        let sourceAccountID = try storage.validateCurrentChatGPTAuth()
        let existingProfile = storage.detectActiveProfile(in: config.profiles)
        if existingProfile == nil {
            guard !config.profiles.contains(requestedProfile),
                  !storage.profileExists(requestedProfile) else {
                throw RelayError.invalidProfile("Profile \(requestedProfile) already exists")
            }
        }

        let server = try makeAppServer(codexHome: storage.paths.codexHome)
        let limits: RateLimitSnapshot
        do {
            limits = try server.rateLimits()
        } catch {
            server.stop()
            throw error
        }
        server.stop()
        guard limits.hasOfficialLimitSignal else {
            throw RelayError.rpc("Missing official rate limit windows")
        }
        let refreshedAccountID = try storage.validateCurrentChatGPTAuth()
        guard refreshedAccountID == sourceAccountID else {
            throw RelayError.verification(
                "Current Codex account changed while it was being imported")
        }

        if let existingProfile {
            try storage.saveCurrentAuth(
                as: existingProfile, expectedAccountID: sourceAccountID)
            try storage.updateAccountQuota(quotaStatus(profile: existingProfile, limits: limits))
            state.activeProfile = existingProfile
            try storage.saveState(state)
            return "Current ChatGPT account is already managed as \(existingProfile); credentials refreshed"
        }

        let originalState = state
        var updatedConfig = config
        do {
            try storage.saveCurrentAuth(
                as: requestedProfile, expectedAccountID: sourceAccountID)
            try storage.updateAccountQuota(quotaStatus(profile: requestedProfile, limits: limits))
            updatedConfig.profiles.append(requestedProfile)
            try storage.saveConfig(updatedConfig)
            state.activeProfile = requestedProfile
            try storage.saveState(state)
        } catch {
            try? storage.deleteProfile(requestedProfile)
            try? storage.saveConfig(config)
            try? storage.saveState(originalState)
            throw error
        }

        return "Imported current ChatGPT account as \(requestedProfile): plan=\(limits.planType ?? "unknown") primary=\(limits.primary?.usedPercent.description ?? "n/a") secondary=\(limits.secondary?.usedPercent.description ?? "n/a")"
    }

    func enrollAuthenticatedProfile(
        _ profile: String,
        limits: RateLimitSnapshot,
        sampledAt: Date = Date()
    ) throws {
        try storage.validateProfileName(profile)
        guard storage.profileExists(profile) else {
            throw RelayError.invalidProfile("Profile \(profile) has not been saved")
        }
        guard limits.hasOfficialLimitSignal else {
            throw RelayError.rpc("Missing official rate limit windows")
        }

        var updatedConfig = try storage.loadConfig()
        if let duplicate = storage.duplicateProfile(
            for: profile,
            among: updatedConfig.profiles
        ) {
            throw RelayError.verification(
                "Profile \(profile) is the same ChatGPT account as \(duplicate). Log in with a different account.")
        }
        if !updatedConfig.profiles.contains(profile) {
            updatedConfig.profiles.append(profile)
        }

        try storage.updateAccountQuota(AccountQuotaStatus(
            profile: profile,
            updatedAt: sampledAt,
            primary: limits.primary,
            secondary: limits.secondary,
            planType: limits.planType,
            error: nil,
            lastAttemptAt: sampledAt
        ))
        try storage.saveConfig(updatedConfig)
    }

    func refreshAllQuotas() throws -> String {
        var state = try storage.loadState()
        guard state.pendingSwitch == nil else {
            throw RelayError.verification(
                "An account switch is being recovered. Wait for the watchdog to finish before refreshing.")
        }

        let activeProfile = storage.detectActiveProfile(in: config.profiles)
        if state.activeProfile != activeProfile {
            state.activeProfile = activeProfile
        }
        guard !config.profiles.isEmpty else {
            try storage.saveState(state)
            return "No managed profiles"
        }

        let orderedProfiles = (activeProfile.map { [$0] } ?? [])
            + config.profiles.filter { $0 != activeProfile }
        var activeLimits: RateLimitSnapshot?
        var failures: [String] = []

        for profile in orderedProfiles {
            let now = Date()
            do {
                let isActive = profile == activeProfile
                let limits: RateLimitSnapshot
                if isActive {
                    let server = try makeAppServer(codexHome: storage.paths.codexHome)
                    defer { server.stop() }
                    limits = try server.rateLimits()
                } else {
                    guard storage.profileExists(profile) else {
                        throw RelayError.missingFile("Saved credential for \(profile)")
                    }
                    limits = try probeStandbyQuota(profile: profile)
                }
                guard limits.hasOfficialLimitSignal else {
                    throw RelayError.rpc("Missing official rate limit windows")
                }
                if isActive {
                    try storage.saveCurrentAuth(as: profile)
                    activeLimits = limits
                }
                try storage.updateAccountQuota(
                    quotaStatus(profile: profile, limits: limits, now: now))
            } catch {
                if profile == activeProfile, shouldPersistActiveCredential(after: error) {
                    _ = try? storage.saveCurrentAuth(as: profile)
                }
                let detail = error.localizedDescription
                failures.append("\(profile)=\(detail)")
                _ = try? recordQuotaFailure(profile: profile, error: error, now: now)
            }
        }

        let summary: String
        if let activeLimits {
            summary = "primary=\(activeLimits.primary?.usedPercent.description ?? "n/a") secondary=\(activeLimits.secondary?.usedPercent.description ?? "n/a") plan=\(activeLimits.planType ?? "unknown")"
        } else {
            summary = "active quota unavailable"
        }
        try storage.saveRuntime(RelayRuntimeStatus(
            updatedAt: Date(), activeProfile: activeProfile,
            primaryUsedPercent: activeLimits?.primary?.usedPercent,
            secondaryUsedPercent: activeLimits?.secondary?.usedPercent,
            planType: activeLimits?.planType, message: "Manual refresh: \(summary)"
        ))

        if failures.isEmpty {
            try storage.saveState(state)
            return "Refreshed \(orderedProfiles.count) profiles: \(summary)"
        }

        try storage.saveState(state)
        throw RelayError.verification(failures.joined(separator: "; "))
    }

    private func shouldPersistActiveCredential(after error: Error) -> Bool {
        !isAuthenticationFailure(error)
    }

    func checkOnce(
        force: Bool = false,
        now: Date = Date(),
        respectingSchedule: Bool = false
    ) throws -> String {
        var state = try storage.loadState()
        let detected = storage.detectActiveProfile(in: config.profiles)
        if let reconciled = try reconcileInterruptedSwitch(state: &state, detectedProfile: detected) {
            return reconciled
        }
        if detected != state.activeProfile {
            state.activeProfile = detected
            try storage.saveState(state)
        }
        guard !config.profiles.isEmpty else {
            return "No managed profiles"
        }
        if respectingSchedule,
           let active = state.activeProfile,
           !QuotaPollingPolicy.isActiveCheckDue(
               status: try storage.accountQuotaStatus(for: active),
               now: now,
               minimumInterval: TimeInterval(config.pollIntervalSeconds))
        {
            if let transaction = state.pendingSwitch,
               transaction.phase == .validated || transaction.phase == .recovering
            {
                return try submitPendingRecovery(state: &state)
            }
            try refreshStandbyQuotas(
                state: &state,
                activeProfile: active,
                now: now,
                respectingSchedule: true
            )
            try storage.saveState(state)
            return "Waiting for the next scheduled quota check"
        }
        let server = try makeAppServer(codexHome: storage.paths.codexHome)
        defer { server.stop() }
        var limits: RateLimitSnapshot?
        var activeAuthenticationError: Error?
        var activeAuthenticationFailures = 0
        do {
            let currentLimits = try server.rateLimits()
            guard currentLimits.hasOfficialLimitSignal else {
                throw RelayError.rpc("Missing official rate limit windows")
            }
            limits = currentLimits
            if let active = state.activeProfile {
                try storage.saveCurrentAuth(as: active)
                try storage.updateAccountQuota(
                    quotaStatus(profile: active, limits: currentLimits, now: now))
            }
        } catch {
            if let active = state.activeProfile,
               shouldPersistActiveCredential(after: error) {
                _ = try? storage.saveCurrentAuth(as: active)
            }
            if isAuthenticationFailure(error) {
                activeAuthenticationError = error
                if let active = state.activeProfile {
                    activeAuthenticationFailures = (
                        try? recordQuotaFailure(
                            profile: active, error: error, now: now)
                    )?.consecutiveAuthenticationFailures ?? 1
                }
            } else {
                if let active = state.activeProfile {
                    _ = try? recordQuotaFailure(
                        profile: active, error: error, now: now)
                }
                throw error
            }
        }
        let summary: String
        if let limits {
            summary = "primary=\(limits.primary?.usedPercent.description ?? "n/a") secondary=\(limits.secondary?.usedPercent.description ?? "n/a") plan=\(limits.planType ?? "unknown")"
        } else {
            summary = "authentication failed \(activeAuthenticationFailures)/\(QuotaPollingPolicy.authenticationFailureThreshold): \(activeAuthenticationError?.localizedDescription ?? "unknown error")"
        }
        let exhausted = force
            || activeAuthenticationFailures >= QuotaPollingPolicy.authenticationFailureThreshold
            || limits?.isExhausted(threshold: config.thresholdUsedPercent) == true
        if !exhausted {
            try? refreshStandbyQuotas(
                state: &state,
                activeProfile: state.activeProfile,
                now: now,
                respectingSchedule: respectingSchedule
            )
        }
        try storage.saveRuntime(RelayRuntimeStatus(
            updatedAt: now, activeProfile: state.activeProfile,
            primaryUsedPercent: limits?.primary?.usedPercent,
            secondaryUsedPercent: limits?.secondary?.usedPercent,
            planType: limits?.planType, message: summary
        ))
        if !exhausted, state.lastError != nil, state.pendingSwitch == nil {
            state.lastError = nil
            try storage.saveState(state)
        }
        guard exhausted else {
            if state.pendingSwitch != nil {
                server.stop()
                let recovery = try submitPendingRecovery(state: &state)
                return "Within allowance: \(summary); \(recovery)"
            }
            return "Within allowance: \(summary)"
        }
        if config.dryRun && !force { return "Automatic switching is disabled: \(summary)" }
        let current = state.activeProfile
        let sourceProfile = current ?? "unmanaged"
        let candidates = ProfileRotation.candidates(profiles: config.scheduledProfiles, current: sourceProfile)
        var target: (profile: String, accountID: String)?
        var failures: [String] = []
        for candidate in candidates where storage.profileExists(candidate) {
            if let current, storage.sameAccount(current, candidate) {
                failures.append("\(candidate)=same account as \(current)")
                continue
            }
            if respectingSchedule,
               let candidateStatus = try storage.accountQuotaStatus(for: candidate),
               candidateStatus.error != nil,
               !QuotaPollingPolicy.isStandbyCheckDue(
                   status: candidateStatus,
                   now: now)
            {
                failures.append("\(candidate)=waiting for authentication retry")
                continue
            }
            do {
                let candidateLimits = try probeStandbyQuota(profile: candidate)
                guard candidateLimits.hasOfficialLimitSignal else {
                    throw RelayError.rpc("Missing official rate limit windows")
                }
                try storage.updateAccountQuota(
                    quotaStatus(profile: candidate, limits: candidateLimits, now: now))
                if candidateLimits.isExhausted(threshold: config.thresholdUsedPercent) {
                    failures.append("\(candidate)=exhausted")
                    continue
                }
                target = (candidate, try storage.profileAccountID(candidate))
                break
            } catch {
                _ = try? recordQuotaFailure(
                    profile: candidate, error: error, now: now)
                failures.append("\(candidate)=\(error.localizedDescription)")
            }
        }
        guard let target else {
            let detail = failures.isEmpty ? "no saved standby profiles" : failures.joined(separator: "; ")
            throw RelayError.verification("No usable standby profile: \(detail)")
        }
        let listedThreads = try server.listThreads(limit: max(config.maxThreadsToWake * 2, 20))
        let scannedThreads = server.unfinishedThreads(from: listedThreads, recentHours: config.recoveryRecentHours)
        let failedRecoveryKeys = state.failedRecoveryKeys ?? []
        let carriedRecovery = state.pendingSwitch?.snapshot.threads.filter {
            !state.completedRecoveryKeys.contains($0.recoveryKey)
                && !failedRecoveryKeys.contains($0.recoveryKey)
        } ?? []
        let carriedThreadIDs = Set(carriedRecovery.map(\.threadId))
        let switchID = UUID()
        let remainingCapacity = max(config.maxThreadsToWake - carriedRecovery.count, 0)
        let newlySelected = RecoverySelector.select(
            scannedThreads.filter { !carriedThreadIDs.contains($0.id) },
            now: Date(), recentHours: config.recoveryRecentHours,
            maxCount: remainingCapacity,
            completedKeys: state.completedRecoveryKeys, switchID: switchID)
        let recovery = Array(carriedRecovery.prefix(config.maxThreadsToWake)) + newlySelected
        let snapshot = SwitchSnapshot(
            id: switchID, createdAt: Date(), sourceProfile: sourceProfile,
            targetProfile: target.profile, threads: recovery)
        let previousAuth: Data
        let sourceAccountID: String?
        if let current {
            if activeAuthenticationFailures > 0 {
                previousAuth = try Data(
                    contentsOf: storage.paths.profileAuth(current))
            } else {
                previousAuth = try storage.saveCurrentAuth(as: current)
            }
            sourceAccountID = try storage.profileAccountID(current)
        } else {
            previousAuth = try Data(contentsOf: storage.paths.activeAuth)
            sourceAccountID = try? storage.activeAccountID()
        }
        try storage.prepareSwitchBackup(id: switchID, authData: previousAuth)
        let previousTransactionID = state.pendingSwitch?.snapshot.id
        state.lastSnapshot = snapshot
        state.pendingSwitch = SwitchTransaction(
            snapshot: snapshot, phase: .prepared,
            sourceAccountID: sourceAccountID, targetAccountID: target.accountID,
            previousLastSwitchAt: state.lastSwitchAt,
            preserveSourceProfileCredential: activeAuthenticationFailures > 0)
        try storage.saveState(state)
        if let previousTransactionID, previousTransactionID != switchID {
            storage.removeSwitchBackup(id: previousTransactionID)
        }
        server.stop()
        return try activatePreparedSwitch(state: &state)
    }

    private func reconcileInterruptedSwitch(state: inout RelayState, detectedProfile: String?) throws -> String? {
        guard var transaction = state.pendingSwitch else { return nil }
        let activeAccountID = try? storage.activeAccountID()

        switch transaction.phase {
        case .prepared:
            guard !config.dryRun,
                  config.isProfileScheduled(transaction.snapshot.targetProfile),
                  storage.profileExists(transaction.snapshot.targetProfile) else {
                return try rollbackPendingSwitch(state: &state, reason: "Prepared switch is no longer allowed")
            }
            if activeAccountID == transaction.targetAccountID {
                transaction.phase = .activated
                state.pendingSwitch = transaction
                try storage.saveState(state)
                return try validateActivatedSwitch(state: &state)
            }
            if activeAccountID == transaction.sourceAccountID
                || (transaction.sourceAccountID == nil && detectedProfile == nil) {
                return try activatePreparedSwitch(state: &state)
            }
            transaction.phase = .completed
            state.pendingSwitch = transaction
            state.activeProfile = detectedProfile
            state.lastError = "Cancelled prepared switch because the active account changed externally"
            try storage.saveState(state)
            return try finalizeCompletedSwitch(state: &state, prefix: "Cancelled interrupted switch")

        case .activated:
            guard !config.dryRun,
                  config.isProfileScheduled(transaction.snapshot.targetProfile),
                  storage.profileExists(transaction.snapshot.targetProfile) else {
                return try rollbackPendingSwitch(state: &state, reason: "Activated switch is no longer allowed")
            }
            if activeAccountID == transaction.targetAccountID {
                return try validateActivatedSwitch(state: &state)
            }
            if activeAccountID == transaction.sourceAccountID {
                transaction.phase = .completed
                state.pendingSwitch = transaction
                state.activeProfile = transaction.snapshot.sourceProfile == "unmanaged"
                    ? detectedProfile : transaction.snapshot.sourceProfile
                state.lastSwitchAt = transaction.previousLastSwitchAt
                state.lastError = "Recovered a switch that had already rolled back"
                try storage.saveState(state)
                return try finalizeCompletedSwitch(state: &state, prefix: "Recovered rolled-back switch")
            }
            if activeAccountID != nil {
                transaction.phase = .completed
                state.pendingSwitch = transaction
                state.activeProfile = detectedProfile
                state.lastError = "Cancelled interrupted switch because the active account changed externally"
                try storage.saveState(state)
                return try finalizeCompletedSwitch(state: &state, prefix: "Cancelled interrupted switch")
            }
            return try rollbackPendingSwitch(state: &state, reason: "Activated target identity could not be verified")

        case .validated, .recovering:
            guard config.isProfileScheduled(transaction.snapshot.targetProfile) else {
                transaction.phase = .completed
                state.pendingSwitch = transaction
                state.lastError = "Stopped recovery because target scheduling was disabled"
                try storage.saveState(state)
                return try finalizeCompletedSwitch(state: &state, prefix: "Stopped disabled recovery")
            }
            guard activeAccountID == transaction.targetAccountID else {
                transaction.phase = .completed
                state.pendingSwitch = transaction
                state.activeProfile = detectedProfile
                state.lastError = "Recovery stopped because the active account changed externally"
                try storage.saveState(state)
                return try finalizeCompletedSwitch(state: &state, prefix: "Stopped stale recovery")
            }
            return nil

        case .completed:
            return try finalizeCompletedSwitch(state: &state, prefix: "Reconciled completed switch")
        }
    }

    private func activatePreparedSwitch(state: inout RelayState) throws -> String {
        guard var transaction = state.pendingSwitch, transaction.phase == .prepared else {
            throw RelayError.verification("Missing prepared switch transaction")
        }
        do {
            stopRecoveryHosts()
            try appController.quit()

            let finalSourceAuth: Data
            if transaction.snapshot.sourceProfile != "unmanaged",
               storage.profileExists(transaction.snapshot.sourceProfile) {
                if transaction.preserveSourceProfileCredential {
                    finalSourceAuth = try Data(contentsOf:
                        storage.paths.profileAuth(transaction.snapshot.sourceProfile))
                    if let expected = transaction.sourceAccountID,
                       try storage.profileAccountID(transaction.snapshot.sourceProfile) != expected
                    {
                        throw RelayError.verification(
                            "Saved source profile identity changed before activation")
                    }
                } else {
                    finalSourceAuth = try storage.saveCurrentAuth(
                        as: transaction.snapshot.sourceProfile)
                    if let expected = transaction.sourceAccountID {
                        try storage.assertActiveAccount(expectedAccountID: expected)
                    }
                }
            } else {
                finalSourceAuth = try Data(contentsOf: storage.paths.activeAuth)
                if let expected = transaction.sourceAccountID {
                    try storage.assertActiveAccount(expectedAccountID: expected)
                }
            }
            try storage.prepareSwitchBackup(id: transaction.snapshot.id, authData: finalSourceAuth)

            _ = try storage.activate(profile: transaction.snapshot.targetProfile)
            try storage.assertActiveAccount(expectedAccountID: transaction.targetAccountID)
            transaction.phase = .activated
            state.pendingSwitch = transaction
            try storage.saveState(state)
        } catch {
            return try rollbackPendingSwitch(
                state: &state,
                reason: "Switch activation failed: \(error.localizedDescription)")
        }
        return try validateActivatedSwitch(state: &state)
    }

    private func validateActivatedSwitch(state: inout RelayState) throws -> String {
        guard var transaction = state.pendingSwitch, transaction.phase == .activated else {
            throw RelayError.verification("Missing activated switch transaction")
        }

        var replacement: (any AppServerServing)?
        let targetLimits: RateLimitSnapshot
        do {
            try storage.assertActiveAccount(expectedAccountID: transaction.targetAccountID)
            let client = try makeAppServer(codexHome: storage.paths.codexHome)
            replacement = client
            targetLimits = try client.rateLimits()
            guard targetLimits.hasOfficialLimitSignal else {
                throw RelayError.rpc("Missing official rate limit windows")
            }
            client.stop()
            replacement = nil
            try storage.assertActiveAccount(expectedAccountID: transaction.targetAccountID)
            try storage.saveCurrentAuth(as: transaction.snapshot.targetProfile)
            guard !targetLimits.isExhausted(threshold: config.thresholdUsedPercent) else {
                throw RelayError.verification(
                    "Standby profile \(transaction.snapshot.targetProfile) is also exhausted")
            }
        } catch {
            replacement?.stop()
            let persistTargetCredential = shouldPersistActiveCredential(after: error)
            if persistTargetCredential {
                _ = try? storage.saveCurrentAuth(as: transaction.snapshot.targetProfile)
            }
            if isAuthenticationFailure(error) || isVerificationFailure(error) {
                return try rollbackPendingSwitch(
                    state: &state,
                    reason: "Target validation failed: \(error.localizedDescription)",
                    persistTargetCredentialBeforeRestore: persistTargetCredential)
            }
            state.lastError = "Target validation will retry: \(error.localizedDescription)"
            try? storage.saveState(state)
            try? appController.openIfNeeded(path: config.chatGPTPath)
            throw error
        }

        try? storage.updateAccountQuota(quotaStatus(
            profile: transaction.snapshot.targetProfile, limits: targetLimits))
        transaction.phase = .validated
        state.pendingSwitch = transaction
        state.activeProfile = transaction.snapshot.targetProfile
        state.lastSwitchAt = Date()
        state.lastError = nil
        try storage.saveState(state)
        try? storage.saveRuntime(RelayRuntimeStatus(
            updatedAt: Date(), activeProfile: transaction.snapshot.targetProfile,
            primaryUsedPercent: targetLimits.primary?.usedPercent,
            secondaryUsedPercent: targetLimits.secondary?.usedPercent,
            planType: targetLimits.planType,
            message: "Switched \(transaction.snapshot.sourceProfile) -> \(transaction.snapshot.targetProfile)"))
        do {
            try appController.openIfNeeded(path: config.chatGPTPath)
        } catch {
            state.lastError = "ChatGPT reopen will retry: \(error.localizedDescription)"
            try? storage.saveState(state)
        }
        let recovery = try submitPendingRecovery(state: &state)
        return "Switched \(transaction.snapshot.sourceProfile) -> \(transaction.snapshot.targetProfile); \(recovery)"
    }

    private func submitPendingRecovery(state: inout RelayState) throws -> String {
        guard var transaction = state.pendingSwitch,
              transaction.phase == .validated || transaction.phase == .recovering else {
            return "no pending recovery"
        }
        guard (try? storage.activeAccountID()) == transaction.targetAccountID else {
            state.lastError = "Recovery paused because the target account is no longer active"
            try? storage.saveState(state)
            return "recovery paused"
        }

        if (transaction.recoveryProtocolVersion ?? 1)
            < SwitchTransaction.currentRecoveryProtocolVersion {
            let transactionKeys = Set(transaction.snapshot.threads.map(\.recoveryKey))
            var failed = state.failedRecoveryKeys ?? []
            failed.subtract(transactionKeys)
            state.failedRecoveryKeys = failed
            transaction.recoveryAttempts.removeAll()
            transaction.recoveryProtocolVersion = SwitchTransaction.currentRecoveryProtocolVersion
            state.pendingSwitch = transaction
            try storage.saveState(state)
        }

        transaction.phase = .recovering
        state.pendingSwitch = transaction
        try storage.saveState(state)
        do {
            try appController.openIfNeeded(path: config.chatGPTPath)
        } catch {
            state.lastError = "ChatGPT reopen will retry: \(error.localizedDescription)"
            try? storage.saveState(state)
        }

        if hasActiveRecoveryHosts {
            return "recovery turns are still running"
        }

        var auditedClient: (any AppServerServing)?
        let failedEntries = transaction.snapshot.threads.filter {
            (state.failedRecoveryKeys ?? []).contains($0.recoveryKey)
        }
        if !failedEntries.isEmpty {
            let auditClient = try makeAppServer(codexHome: storage.paths.codexHome)
            auditedClient = auditClient
            var failed = state.failedRecoveryKeys ?? []
            for entry in failedEntries {
                guard let status = try? auditClient.recoveryMarkerStatus(entry) else { continue }
                switch status {
                case .completed:
                    failed.remove(entry.recoveryKey)
                    state.completedRecoveryKeys.insert(entry.recoveryKey)
                    transaction.recoveryAttempts.removeValue(forKey: entry.recoveryKey)
                    clearTransientRecoveryError(for: entry, state: &state)
                case .inProgress:
                    failed.remove(entry.recoveryKey)
                    transaction.recoveryAttempts.removeValue(forKey: entry.recoveryKey)
                    clearTransientRecoveryError(for: entry, state: &state)
                case .absent, .terminalFailure, .unknown:
                    break
                }
            }
            state.failedRecoveryKeys = failed
            state.pendingSwitch = transaction
            try storage.saveState(state)
        }

        let pending = transaction.snapshot.threads.filter {
            !state.completedRecoveryKeys.contains($0.recoveryKey)
                && !(state.failedRecoveryKeys ?? []).contains($0.recoveryKey)
        }
        if pending.isEmpty {
            auditedClient?.stop()
            let failed = state.failedRecoveryKeys ?? []
            if !transaction.snapshot.threads.contains(where: { failed.contains($0.recoveryKey) }) {
                state.lastError = nil
            }
            transaction.phase = .completed
            state.pendingSwitch = transaction
            try storage.saveState(state)
            return try finalizeCompletedSwitch(state: &state, prefix: "recovery complete")
        }

        let client = try auditedClient ?? makeAppServer(codexHome: storage.paths.codexHome)
        var submitted = 0
        var abandoned = 0
        var watchedEntries: [RecoveryEntry] = []
        for entry in pending.prefix(max(config.maxConcurrentRecoveryTurns, 1)) {
            let existingStatus: RecoveryMarkerStatus
            do {
                existingStatus = try client.recoveryMarkerStatus(entry)
                if existingStatus == .completed {
                    state.completedRecoveryKeys.insert(entry.recoveryKey)
                    transaction.recoveryAttempts.removeValue(forKey: entry.recoveryKey)
                    clearTransientRecoveryError(for: entry, state: &state)
                    state.pendingSwitch = transaction
                    try storage.saveState(state)
                    continue
                }
                if existingStatus == .unknown {
                    if recordRecoveryProblem(
                        for: entry,
                        transaction: &transaction,
                        state: &state
                    ) {
                        abandoned += 1
                    }
                    state.pendingSwitch = transaction
                    try storage.saveState(state)
                    continue
                }
                if existingStatus == .inProgress {
                    watchedEntries.append(entry)
                    clearTransientRecoveryError(for: entry, state: &state)
                    state.pendingSwitch = transaction
                    try storage.saveState(state)
                    continue
                }
                if existingStatus == .terminalFailure {
                    if transaction.recoveryAttempts[entry.recoveryKey] == nil {
                        if recordRecoveryProblem(
                            for: entry,
                            transaction: &transaction,
                            state: &state
                        ) {
                            abandoned += 1
                            state.pendingSwitch = transaction
                            try storage.saveState(state)
                            continue
                        }
                    }
                }
            } catch {
                if recordRecoveryProblem(
                    for: entry,
                    transaction: &transaction,
                    state: &state
                ) {
                    abandoned += 1
                }
                state.pendingSwitch = transaction
                try storage.saveState(state)
                continue
            }
            do {
                try client.resumeAndWake(entry)
                submitted += 1
                watchedEntries.append(entry)
                clearTransientRecoveryError(for: entry, state: &state)
            } catch {
                do {
                    switch try client.recoveryMarkerStatus(entry) {
                    case .completed:
                        state.completedRecoveryKeys.insert(entry.recoveryKey)
                        transaction.recoveryAttempts.removeValue(forKey: entry.recoveryKey)
                        clearTransientRecoveryError(for: entry, state: &state)
                    case .inProgress:
                        submitted += 1
                        watchedEntries.append(entry)
                        clearTransientRecoveryError(for: entry, state: &state)
                    case .absent, .terminalFailure:
                        if recordRecoveryProblem(
                            for: entry,
                            transaction: &transaction,
                            state: &state
                        ) {
                            abandoned += 1
                        }
                    case .unknown:
                        if recordRecoveryProblem(
                            for: entry,
                            transaction: &transaction,
                            state: &state
                        ) {
                            abandoned += 1
                        }
                    }
                } catch {
                    if recordRecoveryProblem(
                        for: entry,
                        transaction: &transaction,
                        state: &state
                    ) {
                        abandoned += 1
                    }
                }
            }
            state.pendingSwitch = transaction
            try storage.saveState(state)
        }

        if watchedEntries.isEmpty {
            client.stop()
        } else {
            retainRecoveryHost(client, entries: watchedEntries)
        }

        let remaining = transaction.snapshot.threads.filter {
            !state.completedRecoveryKeys.contains($0.recoveryKey)
                && !(state.failedRecoveryKeys ?? []).contains($0.recoveryKey)
        }.count
        if remaining == 0 {
            let failed = state.failedRecoveryKeys ?? []
            if !transaction.snapshot.threads.contains(where: { failed.contains($0.recoveryKey) }) {
                state.lastError = nil
            }
            transaction.phase = .completed
            state.pendingSwitch = transaction
            try storage.saveState(state)
            return try finalizeCompletedSwitch(
                state: &state,
                prefix: "submitted \(submitted) recovery turns, abandoned \(abandoned)")
        }
        return "submitted \(submitted) recovery turns, \(remaining) pending"
    }

    private func terminalRecoveryError() -> String {
        "有任务自动恢复失败（连续 3 次未完成），请在 ChatGPT 中手动继续"
    }

    @discardableResult
    private func recordRecoveryProblem(
        for entry: RecoveryEntry,
        transaction: inout SwitchTransaction,
        state: inout RelayState
    ) -> Bool {
        let attempts = (transaction.recoveryAttempts[entry.recoveryKey] ?? 0) + 1
        transaction.recoveryAttempts[entry.recoveryKey] = attempts
        guard attempts >= 3 else {
            clearTransientRecoveryError(for: entry, state: &state)
            return false
        }
        var failed = state.failedRecoveryKeys ?? []
        failed.insert(entry.recoveryKey)
        state.failedRecoveryKeys = failed
        state.lastError = terminalRecoveryError()
        return true
    }

    private func clearTransientRecoveryError(
        for entry: RecoveryEntry,
        state: inout RelayState
    ) {
        guard let error = state.lastError else { return }
        let prefixes = [
            "Recovery turn \(entry.threadId) did not complete (",
            "Recovery marker status for \(entry.threadId) is unknown;",
            "Recovery marker check for \(entry.threadId) will retry:",
            "Wake \(entry.threadId) failed (",
            "Wake \(entry.threadId) had an ambiguous response;",
        ]
        if prefixes.contains(where: error.hasPrefix) {
            state.lastError = nil
        }
    }

    private var hasActiveRecoveryHosts: Bool {
        recoveryHostsLock.lock()
        let active = !recoveryHosts.isEmpty
        recoveryHostsLock.unlock()
        return active
    }

    private func retainRecoveryHost(_ client: any AppServerServing, entries: [RecoveryEntry]) {
        let hostID = UUID()
        recoveryHostsLock.lock()
        recoveryHosts[hostID] = client
        recoveryHostsLock.unlock()

        Thread.detachNewThread { [weak self] in
            let completedThreadIDs = client.waitForTurns(
                entries,
                timeoutSeconds: 21_600
            )
            self?.recordRecoveryHostOutcome(
                client: client,
                entries: entries,
                completedThreadIDs: completedThreadIDs
            )
            client.stop()
            guard let self else { return }
            self.recoveryHostsLock.lock()
            self.recoveryHosts.removeValue(forKey: hostID)
            self.recoveryHostsLock.unlock()
        }
    }

    private func recordRecoveryHostOutcome(
        client: any AppServerServing,
        entries: [RecoveryEntry],
        completedThreadIDs: Set<String>
    ) {
        guard var state = try? storage.loadState(),
              var transaction = state.pendingSwitch
        else { return }
        let transactionKeys = Set(transaction.snapshot.threads.map(\.recoveryKey))
        var changed = false

        for entry in entries where transactionKeys.contains(entry.recoveryKey) {
            guard !state.completedRecoveryKeys.contains(entry.recoveryKey),
                  !(state.failedRecoveryKeys ?? []).contains(entry.recoveryKey)
            else { continue }

            let finalStatus: RecoveryMarkerStatus?
            if completedThreadIDs.contains(entry.threadId) {
                finalStatus = .completed
            } else {
                finalStatus = try? client.recoveryMarkerStatus(entry)
            }
            switch finalStatus {
            case .completed:
                state.completedRecoveryKeys.insert(entry.recoveryKey)
                transaction.recoveryAttempts.removeValue(forKey: entry.recoveryKey)
                clearTransientRecoveryError(for: entry, state: &state)
                changed = true
            case .inProgress:
                break
            case .absent, .terminalFailure, .unknown, nil:
                _ = recordRecoveryProblem(
                    for: entry,
                    transaction: &transaction,
                    state: &state
                )
                changed = true
            }
        }

        guard changed else { return }
        state.pendingSwitch = transaction
        try? storage.saveState(state)
    }

    private func stopRecoveryHosts() {
        recoveryHostsLock.lock()
        let hosts = Array(recoveryHosts.values)
        recoveryHosts.removeAll()
        recoveryHostsLock.unlock()
        hosts.forEach { $0.stop() }
    }

    private func rollbackPendingSwitch(
        state: inout RelayState,
        reason: String,
        persistTargetCredentialBeforeRestore: Bool = true
    ) throws -> String {
        guard var transaction = state.pendingSwitch else {
            throw RelayError.verification(reason)
        }
        if let activeAccountID = try? storage.activeAccountID(),
           activeAccountID != transaction.sourceAccountID,
           activeAccountID != transaction.targetAccountID {
            transaction.phase = .completed
            state.pendingSwitch = transaction
            state.activeProfile = storage.detectActiveProfile(in: config.profiles)
            state.lastError = "\(reason); rollback cancelled because the active account changed externally"
            try storage.saveState(state)
            return try finalizeCompletedSwitch(state: &state, prefix: "Cancelled stale rollback")
        }
        do {
            try appController.quit()
        } catch {
            state.lastError = "\(reason); rollback waiting for ChatGPT to stop: \(error.localizedDescription)"
            try? storage.saveState(state)
            throw RelayError.verification(state.lastError ?? reason)
        }

        if persistTargetCredentialBeforeRestore,
           (try? storage.activeAccountID()) == transaction.targetAccountID,
           storage.profileExists(transaction.snapshot.targetProfile) {
            _ = try? storage.saveCurrentAuth(as: transaction.snapshot.targetProfile)
        }
        do {
            let backup = try storage.loadSwitchBackup(id: transaction.snapshot.id)
            try storage.restoreAuth(backup)
            if let sourceAccountID = transaction.sourceAccountID {
                try storage.assertActiveAccount(expectedAccountID: sourceAccountID)
            }
        } catch {
            state.lastError = "\(reason); credential rollback failed: \(error.localizedDescription)"
            try? storage.saveState(state)
            throw RelayError.verification(state.lastError ?? reason)
        }

        state.activeProfile = transaction.snapshot.sourceProfile == "unmanaged"
            ? storage.detectActiveProfile(in: config.profiles)
            : transaction.snapshot.sourceProfile
        state.lastSwitchAt = transaction.previousLastSwitchAt
        state.lastError = reason
        transaction.phase = .completed
        state.pendingSwitch = transaction
        try storage.saveState(state)
        return try finalizeCompletedSwitch(state: &state, prefix: "Rolled back switch")
    }

    private func finalizeCompletedSwitch(state: inout RelayState, prefix: String) throws -> String {
        guard let transaction = state.pendingSwitch, transaction.phase == .completed else {
            return prefix
        }
        try appController.openIfNeeded(path: config.chatGPTPath)
        state.pendingSwitch = nil
        try storage.saveState(state)
        storage.removeSwitchBackup(id: transaction.snapshot.id)
        return prefix
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        let authenticationFailures = [
            "401", "403", "unauthorized", "forbidden", "token_invalidated",
            "invalid token", "token expired", "not authenticated",
            "authentication failed", "authentication required", "login required",
            "authentication token", "refresh token",
        ]
        return authenticationFailures.contains { message.contains($0) }
    }

    private func isVerificationFailure(_ error: Error) -> Bool {
        guard let relayError = error as? RelayError else { return false }
        if case .verification = relayError { return true }
        return false
    }

    func run(parentPID: pid_t? = nil) throws -> Never {
        if let parentPID { monitorParent(parentPID) }
        while true {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            do {
                let result = try checkOnce(respectingSchedule: true)
                writeLog("[\(timestamp)] \(result)")
            } catch {
                writeLog("[\(timestamp)] ERROR \(error.localizedDescription)")
                if var state = try? storage.loadState() {
                    state.lastError = error.localizedDescription
                    try? storage.saveState(state)
                    try? storage.saveRuntime(RelayRuntimeStatus(
                        updatedAt: Date(), activeProfile: state.activeProfile,
                        primaryUsedPercent: nil, secondaryUsedPercent: nil,
                        planType: nil, message: "ERROR \(error.localizedDescription)"
                    ))
                }
            }
            Thread.sleep(forTimeInterval: Double(config.pollIntervalSeconds))
        }
    }

    private func writeLog(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private func quotaStatus(
        profile: String,
        limits: RateLimitSnapshot,
        now: Date = Date()
    ) -> AccountQuotaStatus {
        AccountQuotaStatus(
            profile: profile,
            updatedAt: now,
            primary: limits.primary,
            secondary: limits.secondary,
            planType: limits.planType,
            error: nil,
            duplicateOf: storage.duplicateProfile(
                for: profile, among: config.profiles),
            lastAttemptAt: now,
            consecutiveAuthenticationFailures: 0
        )
    }

    @discardableResult
    private func recordQuotaFailure(
        profile: String,
        error: Error,
        now: Date
    ) throws -> AccountQuotaStatus {
        let previous = try storage.accountQuotaStatus(for: profile)
        let authenticationFailure = isAuthenticationFailure(error)
        let failureCount = authenticationFailure
            ? (previous?.consecutiveAuthenticationFailures ?? 0) + 1
            : 0
        let status = AccountQuotaStatus(
            profile: profile,
            updatedAt: previous?.updatedAt ?? now,
            primary: previous?.primary,
            secondary: previous?.secondary,
            planType: previous?.planType,
            error: error.localizedDescription,
            duplicateOf: storage.duplicateProfile(
                for: profile, among: config.profiles),
            lastAttemptAt: now,
            consecutiveAuthenticationFailures: failureCount
        )
        try storage.updateAccountQuota(status)
        return status
    }

    private func probeStandbyQuota(profile: String) throws -> RateLimitSnapshot {
        let probeHome = try storage.prepareProfileProbeHome(profile)
        defer { storage.removeProfileProbeHome(probeHome) }
        var probe: (any AppServerServing)?
        do {
            let client = try makeAppServer(codexHome: probeHome)
            probe = client
            let limits = try client.rateLimits()
            client.stop()
            probe = nil
            try storage.commitProfileProbeAuth(profile, from: probeHome)
            return limits
        } catch {
            probe?.stop()
            if shouldPersistActiveCredential(after: error) {
                try? storage.commitProfileProbeAuth(profile, from: probeHome)
            }
            throw error
        }
    }

    private func refreshStandbyQuotas(
        state: inout RelayState,
        activeProfile: String?,
        now: Date,
        respectingSchedule: Bool
    ) throws {
        let scheduledProfiles = config.scheduledProfiles
        guard !scheduledProfiles.isEmpty else { return }
        let start = (state.nextQuotaProfileIndex ?? 0) % scheduledProfiles.count
        for offset in 0..<scheduledProfiles.count {
            let index = (start + offset) % scheduledProfiles.count
            let profile = scheduledProfiles[index]
            guard profile != activeProfile, storage.profileExists(profile) else { continue }
            if respectingSchedule,
               !QuotaPollingPolicy.isStandbyCheckDue(
                   status: try storage.accountQuotaStatus(for: profile),
                   now: now)
            {
                continue
            }
            do {
                let limits = try probeStandbyQuota(profile: profile)
                try storage.updateAccountQuota(
                    quotaStatus(profile: profile, limits: limits, now: now))
            } catch {
                _ = try recordQuotaFailure(profile: profile, error: error, now: now)
            }
            state.nextQuotaProfileIndex = (index + 1) % scheduledProfiles.count
            try storage.saveState(state)
            if !respectingSchedule { return }
        }
    }

    private func monitorParent(_ parentPID: pid_t) {
        Thread.detachNewThread {
            while Darwin.kill(parentPID, 0) == 0 || errno == EPERM {
                Thread.sleep(forTimeInterval: 1)
            }
            Darwin._exit(0)
        }
    }
}
