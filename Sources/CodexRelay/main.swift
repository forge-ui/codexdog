import Foundation
import Darwin

func parentPIDOption(in arguments: [String]) throws -> pid_t? {
    guard let index = arguments.firstIndex(of: "--parent-pid") else { return nil }
    guard arguments.indices.contains(index + 1),
          let parsed = Int32(arguments[index + 1]), parsed > 0 else {
        throw RelayError.invalidArguments("--parent-pid requires a positive process id")
    }
    return parsed
}

func isolateProcessGroup() throws {
    if Darwin.setpgid(0, 0) != 0, Darwin.getpgrp() != Darwin.getpid() {
        throw RelayError.process("Could not isolate helper process group: \(String(cString: strerror(errno)))")
    }
}

func monitorParentForProcessGroup(_ parentPID: pid_t) {
    Thread.detachNewThread {
        while Darwin.kill(parentPID, 0) == 0 || errno == EPERM {
            Thread.sleep(forTimeInterval: 1)
        }
        processDescendants(of: Darwin.getpid()).reversed().forEach { Darwin.kill($0, SIGKILL) }
        let group = Darwin.getpgrp()
        if group == Darwin.getpid() {
            _ = Darwin.kill(-group, SIGTERM)
        }
        Darwin._exit(0)
    }
}

func processDescendants(of parentPID: pid_t) -> [pid_t] {
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
    return children + children.flatMap { processDescendants(of: $0) }
}

func usage() {
    print("""
    CodexRelay 0.8.1
      codex-relay init
      codex-relay profile login <name>
      codex-relay profile import-current <name>
      codex-relay profile verify <name>
      codex-relay profile save <name>
      codex-relay profile list
      codex-relay profile disable <name>
      codex-relay profile enable <name>
      codex-relay profile delete <name>
      codex-relay config auto-switch <on|off>
      codex-relay refresh
      codex-relay check [--force]
      codex-relay diagnose
      codex-relay run
      codex-relay status
      codex-relay install
      codex-relay uninstall
    """)
}

func requireIdleSwitchTransaction(_ storage: RelayStorage) throws {
    guard try storage.loadState().pendingSwitch == nil else {
        throw RelayError.verification(
            "An account switch is being recovered. Wait for the watchdog to finish before changing accounts.")
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let initial = RelayConfig.default
    let initialPaths = RelayPaths(config: initial)
    let advisoryLock = RelayAdvisoryLock(root: initialPaths.root)
    let lockedCommands = ["init", "profile", "config", "refresh", "check", "diagnose", "run"]
    let isProfileLogin = arguments.first == "profile"
        && arguments.indices.contains(1) && arguments[1] == "login"
    var operationLease = lockedCommands.contains(arguments.first ?? "") && !isProfileLogin
        ? try advisoryLock.acquire()
        : nil
    defer { operationLease?.release() }
    var storage = RelayStorage(paths: initialPaths)
    try storage.bootstrap()
    let config = try storage.loadConfig()
    let paths = RelayPaths(config: config)
    if paths.codexHome != initialPaths.codexHome {
        storage = RelayStorage(paths: paths)
        try storage.bootstrap()
    }
    let engine = RelayEngine(storage: storage, config: config)
    switch arguments.first {
    case "init":
        print("Initialized \(paths.root.path). Enroll one or more profiles with profile login <name>.")
    case "profile" where arguments.count >= 2:
        switch arguments[1] {
        case "login" where arguments.count == 3 || arguments.count == 5:
            let name = arguments[2]
            let parentPID = try parentPIDOption(in: arguments)
            if parentPID != nil { try isolateProcessGroup() }
            let preflightLease = try advisoryLock.acquire()
            let preflightConfig = try storage.loadConfig()
            guard !preflightConfig.profiles.contains(name), !storage.profileExists(name) else {
                preflightLease.release()
                throw RelayError.invalidProfile("Profile \(name) already exists")
            }
            preflightLease.release()
            let profileHome = try storage.prepareProfileHome(name)
            let login = Process()
            login.executableURL = URL(fileURLWithPath: config.codexBinaryPath)
            login.arguments = ["login", "--device-auth"]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = profileHome.path
            login.environment = environment
            try login.run()
            if let parentPID { monitorParentForProcessGroup(parentPID) }
            login.waitUntilExit()
            guard login.terminationStatus == 0 else {
                throw RelayError.process("Codex login failed for \(name) with status \(login.terminationStatus)")
            }
            try storage.secureProfileAuth(name)
            let verification = try AppServerClient(binaryPath: config.codexBinaryPath, codexHome: profileHome)
            defer { verification.stop() }
            let limits = try verification.rateLimits()
            operationLease = try advisoryLock.acquire()
            try requireIdleSwitchTransaction(storage)
            var updatedConfig = try storage.loadConfig()
            if let duplicate = storage.duplicateProfile(for: name, among: updatedConfig.profiles) {
                throw RelayError.verification("Profile \(name) is the same ChatGPT account as \(duplicate). Log in with a different account.")
            }
            if !updatedConfig.profiles.contains(name) {
                updatedConfig.profiles.append(name)
                try storage.saveConfig(updatedConfig)
            }
            print("Logged in \(name): plan=\(limits.planType ?? "unknown") primary=\(limits.primary?.usedPercent.description ?? "n/a") secondary=\(limits.secondary?.usedPercent.description ?? "n/a")")
        case "verify" where arguments.count == 3:
            let name = arguments[2]
            let profileHome = try storage.prepareProfileHome(name)
            guard storage.profileExists(name) else {
                throw RelayError.invalidProfile("Profile \(name) has not been saved")
            }
            let verification = try AppServerClient(binaryPath: config.codexBinaryPath, codexHome: profileHome)
            defer { verification.stop() }
            let limits = try verification.rateLimits()
            try storage.updateAccountQuota(AccountQuotaStatus(
                profile: name, updatedAt: Date(), primary: limits.primary,
                secondary: limits.secondary, planType: limits.planType, error: nil,
                duplicateOf: storage.duplicateProfile(for: name, among: config.profiles)
            ))
            print("Verified \(name): plan=\(limits.planType ?? "unknown") primary=\(limits.primary?.usedPercent.description ?? "n/a") secondary=\(limits.secondary?.usedPercent.description ?? "n/a")")
        case "import-current" where arguments.count == 3:
            print(try engine.importCurrentProfile(as: arguments[2]))
        case "save" where arguments.count == 3:
            try requireIdleSwitchTransaction(storage)
            let name = arguments[2]
            try storage.saveCurrentAuth(as: name)
            var updatedConfig = try storage.loadConfig()
            if !updatedConfig.profiles.contains(name) {
                updatedConfig.profiles.append(name)
                try storage.saveConfig(updatedConfig)
            }
            var state = try storage.loadState()
            state.activeProfile = name
            try storage.saveState(state)
            print("Saved current ChatGPT auth as \(name)")
        case "list":
            let state = try storage.loadState()
            for name in config.profiles {
                let scheduling = config.isProfileScheduled(name) ? "scheduled" : "paused"
                print("\(state.activeProfile == name ? "*" : " ") \(name): \(storage.profileExists(name) ? "saved" : "missing"), \(scheduling)")
            }
        case "disable" where arguments.count == 3:
            try requireIdleSwitchTransaction(storage)
            let name = arguments[2]
            var updatedConfig = try storage.loadConfig()
            guard updatedConfig.profiles.contains(name) else {
                throw RelayError.invalidProfile("Profile \(name) is not configured")
            }
            updatedConfig.setProfile(name, scheduled: false)
            try storage.saveConfig(updatedConfig)
            print("Paused scheduling for \(name)")
        case "enable" where arguments.count == 3:
            try requireIdleSwitchTransaction(storage)
            let name = arguments[2]
            var updatedConfig = try storage.loadConfig()
            guard updatedConfig.profiles.contains(name) else {
                throw RelayError.invalidProfile("Profile \(name) is not configured")
            }
            updatedConfig.setProfile(name, scheduled: true)
            try storage.saveConfig(updatedConfig)
            print("Resumed scheduling for \(name)")
        case "delete" where arguments.count == 3:
            try requireIdleSwitchTransaction(storage)
            let name = arguments[2]
            var updatedConfig = try storage.loadConfig()
            guard updatedConfig.profiles.contains(name) else {
                throw RelayError.invalidProfile("Profile \(name) is not configured")
            }
            let wasActive = storage.detectActiveProfile(in: updatedConfig.profiles) == name
            updatedConfig.removeProfile(name)
            try storage.saveConfig(updatedConfig)
            var state = try storage.loadState()
            if state.activeProfile == name || wasActive { state.activeProfile = nil }
            state.nextQuotaProfileIndex = nil
            try storage.saveState(state)
            try storage.deleteProfile(name)
            print("Deleted \(name) from CodexRelay")
        default:
            throw RelayError.invalidArguments(
                "Expected profile login/import-current/save/verify/disable/enable/delete <name>, or profile list")
        }
    case "config" where arguments.count == 3 && arguments[1] == "auto-switch":
        var updatedConfig = try storage.loadConfig()
        switch arguments[2] {
        case "on": updatedConfig.dryRun = false
        case "off": updatedConfig.dryRun = true
        default: throw RelayError.invalidArguments("Expected config auto-switch <on|off>")
        }
        try storage.saveConfig(updatedConfig)
        print("Automatic switching \(updatedConfig.dryRun ? "disabled" : "enabled")")
    case "refresh": print(try engine.refreshAllQuotas())
    case "check": print(try engine.checkOnce(force: arguments.contains("--force")))
    case "diagnose": print(try engine.diagnose())
    case "run":
        let parentPID = try parentPIDOption(in: arguments)
        if parentPID != nil { try isolateProcessGroup() }
        operationLease?.release()
        operationLease = nil
        try engine.runWithAdvisoryLock(advisoryLock, parentPID: parentPID)
    case "status":
        let state = try storage.loadState()
        let data = try JSONEncoder().encode(state)
        print(String(data: data, encoding: .utf8) ?? "{}")
    case "install":
        let path = try LaunchAgentManager().install(executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
        print("Installed \(path.path)")
    case "uninstall": try LaunchAgentManager().uninstall(); print("Uninstalled LaunchAgent")
    default: usage()
    }
} catch {
    fputs("codex-relay: \(error.localizedDescription)\n", stderr)
    exit(1)
}
