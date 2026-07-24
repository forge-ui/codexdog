import Foundation

struct RelayConfig: Codable, Equatable, Sendable {
    var profiles: [String] = []
    var disabledProfiles: [String] = []
    var thresholdUsedPercent = 99
    var pollIntervalSeconds = 30
    var switchCooldownSeconds = 0
    var recoveryRecentHours = 24
    var maxThreadsToWake = 20
    var maxConcurrentRecoveryTurns = 3
    var dryRun = true
    var chatGPTPath = "/Applications/ChatGPT.app"
    var codexBinaryPath = "/Applications/ChatGPT.app/Contents/Resources/codex"
    var codexHome = "~/.codex"

    static let `default` = RelayConfig()

    var scheduledProfiles: [String] {
        let disabled = Set(disabledProfiles)
        return profiles.filter { !disabled.contains($0) }
    }

    func isProfileScheduled(_ profile: String) -> Bool {
        profiles.contains(profile) && !disabledProfiles.contains(profile)
    }

    mutating func setProfile(_ profile: String, scheduled: Bool) {
        guard profiles.contains(profile) else { return }
        if scheduled {
            disabledProfiles.removeAll { $0 == profile }
        } else if !disabledProfiles.contains(profile) {
            disabledProfiles.append(profile)
        }
    }

    mutating func removeProfile(_ profile: String) {
        profiles.removeAll { $0 == profile }
        disabledProfiles.removeAll { $0 == profile }
    }

    init(
        profiles: [String] = [],
        disabledProfiles: [String] = [],
        thresholdUsedPercent: Int = 99,
        pollIntervalSeconds: Int = 30,
        switchCooldownSeconds: Int = 0,
        recoveryRecentHours: Int = 24,
        maxThreadsToWake: Int = 20,
        maxConcurrentRecoveryTurns: Int = 3,
        dryRun: Bool = true,
        chatGPTPath: String = "/Applications/ChatGPT.app",
        codexBinaryPath: String = "/Applications/ChatGPT.app/Contents/Resources/codex",
        codexHome: String = "~/.codex")
    {
        self.profiles = profiles
        self.disabledProfiles = disabledProfiles
        self.thresholdUsedPercent = thresholdUsedPercent
        self.pollIntervalSeconds = pollIntervalSeconds
        self.switchCooldownSeconds = switchCooldownSeconds
        self.recoveryRecentHours = recoveryRecentHours
        self.maxThreadsToWake = maxThreadsToWake
        self.maxConcurrentRecoveryTurns = maxConcurrentRecoveryTurns
        self.dryRun = dryRun
        self.chatGPTPath = chatGPTPath
        self.codexBinaryPath = codexBinaryPath
        self.codexHome = codexHome
    }

    private enum CodingKeys: String, CodingKey {
        case profiles, disabledProfiles, thresholdUsedPercent, pollIntervalSeconds
        case switchCooldownSeconds, recoveryRecentHours, maxThreadsToWake
        case maxConcurrentRecoveryTurns, dryRun, chatGPTPath, codexBinaryPath, codexHome
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            profiles: try values.decodeIfPresent([String].self, forKey: .profiles) ?? [],
            disabledProfiles: try values.decodeIfPresent([String].self, forKey: .disabledProfiles) ?? [],
            thresholdUsedPercent: try values.decodeIfPresent(Int.self, forKey: .thresholdUsedPercent) ?? 99,
            pollIntervalSeconds: try values.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 30,
            switchCooldownSeconds: try values.decodeIfPresent(Int.self, forKey: .switchCooldownSeconds) ?? 0,
            recoveryRecentHours: try values.decodeIfPresent(Int.self, forKey: .recoveryRecentHours) ?? 24,
            maxThreadsToWake: try values.decodeIfPresent(Int.self, forKey: .maxThreadsToWake) ?? 20,
            maxConcurrentRecoveryTurns: try values.decodeIfPresent(Int.self, forKey: .maxConcurrentRecoveryTurns) ?? 3,
            dryRun: try values.decodeIfPresent(Bool.self, forKey: .dryRun) ?? true,
            chatGPTPath: try values.decodeIfPresent(String.self, forKey: .chatGPTPath)
                ?? "/Applications/ChatGPT.app",
            codexBinaryPath: try values.decodeIfPresent(String.self, forKey: .codexBinaryPath)
                ?? "/Applications/ChatGPT.app/Contents/Resources/codex",
            codexHome: try values.decodeIfPresent(String.self, forKey: .codexHome) ?? "~/.codex")
    }
}

struct RateLimitWindow: Codable, Equatable, Sendable {
    let usedPercent: Int
    let resetsAt: Int64?
    let windowDurationMins: Int?

    init(usedPercent: Int, resetsAt: Int64?, windowDurationMins: Int? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
    }
}

struct RateLimitSnapshot: Equatable, Sendable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let reachedReason: String?
    let planType: String?

    var hasOfficialLimitSignal: Bool {
        primary != nil || secondary != nil || reachedReason != nil
    }

    func isExhausted(threshold: Int) -> Bool {
        reachedReason != nil || primary?.usedPercent ?? 0 >= threshold || secondary?.usedPercent ?? 0 >= threshold
    }
}

struct ThreadRecord: Codable, Equatable, Sendable {
    let id: String
    let preview: String?
    let cwd: String?
    let updatedAt: Int64?
    let status: String
}

struct RecoveryEntry: Codable, Equatable, Sendable {
    let threadId: String
    let cwd: String?
    let previousStatus: String
    let recoveryKey: String
}

enum RecoveryMarkerStatus: Equatable, Sendable {
    case absent
    case inProgress
    case completed
    case terminalFailure
    case unknown
}

struct SwitchSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let sourceProfile: String
    let targetProfile: String
    let threads: [RecoveryEntry]
}

enum SwitchPhase: String, Codable, Equatable, Sendable {
    case prepared
    case activated
    case validated
    case recovering
    case completed
}

struct SwitchTransaction: Codable, Equatable, Sendable {
    static let currentRecoveryProtocolVersion = 2

    var snapshot: SwitchSnapshot
    var phase: SwitchPhase
    let sourceAccountID: String?
    let targetAccountID: String
    let previousLastSwitchAt: Date?
    let preserveSourceProfileCredential: Bool
    var recoveryAttempts: [String: Int] = [:]
    var recoveryProtocolVersion: Int?

    init(snapshot: SwitchSnapshot, phase: SwitchPhase, sourceAccountID: String?,
         targetAccountID: String, previousLastSwitchAt: Date?,
         preserveSourceProfileCredential: Bool = false,
         recoveryAttempts: [String: Int] = [:],
         recoveryProtocolVersion: Int? = SwitchTransaction.currentRecoveryProtocolVersion) {
        self.snapshot = snapshot
        self.phase = phase
        self.sourceAccountID = sourceAccountID
        self.targetAccountID = targetAccountID
        self.previousLastSwitchAt = previousLastSwitchAt
        self.preserveSourceProfileCredential = preserveSourceProfileCredential
        self.recoveryAttempts = recoveryAttempts
        self.recoveryProtocolVersion = recoveryProtocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case snapshot, phase, sourceAccountID, targetAccountID, previousLastSwitchAt
        case preserveSourceProfileCredential, recoveryAttempts, recoveryProtocolVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try values.decode(SwitchSnapshot.self, forKey: .snapshot)
        phase = try values.decode(SwitchPhase.self, forKey: .phase)
        sourceAccountID = try values.decodeIfPresent(String.self, forKey: .sourceAccountID)
        targetAccountID = try values.decode(String.self, forKey: .targetAccountID)
        previousLastSwitchAt = try values.decodeIfPresent(Date.self, forKey: .previousLastSwitchAt)
        preserveSourceProfileCredential = try values.decodeIfPresent(
            Bool.self, forKey: .preserveSourceProfileCredential) ?? false
        recoveryAttempts = try values.decodeIfPresent([String: Int].self, forKey: .recoveryAttempts) ?? [:]
        recoveryProtocolVersion = try values.decodeIfPresent(Int.self, forKey: .recoveryProtocolVersion)
    }
}

struct RelayState: Codable, Equatable, Sendable {
    var activeProfile: String?
    var lastSwitchAt: Date?
    var lastError: String?
    var completedRecoveryKeys: Set<String> = []
    var failedRecoveryKeys: Set<String>?
    var lastSnapshot: SwitchSnapshot?
    var nextQuotaProfileIndex: Int?
    var pendingSwitch: SwitchTransaction?

    init(activeProfile: String? = nil, lastSwitchAt: Date? = nil, lastError: String? = nil,
         completedRecoveryKeys: Set<String> = [], failedRecoveryKeys: Set<String>? = nil,
         lastSnapshot: SwitchSnapshot? = nil, nextQuotaProfileIndex: Int? = nil,
         pendingSwitch: SwitchTransaction? = nil) {
        self.activeProfile = activeProfile
        self.lastSwitchAt = lastSwitchAt
        self.lastError = lastError
        self.completedRecoveryKeys = completedRecoveryKeys
        self.failedRecoveryKeys = failedRecoveryKeys
        self.lastSnapshot = lastSnapshot
        self.nextQuotaProfileIndex = nextQuotaProfileIndex
        self.pendingSwitch = pendingSwitch
    }

    private enum CodingKeys: String, CodingKey {
        case activeProfile, lastSwitchAt, lastError, completedRecoveryKeys, failedRecoveryKeys
        case lastSnapshot, nextQuotaProfileIndex, pendingSwitch
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activeProfile = try values.decodeIfPresent(String.self, forKey: .activeProfile)
        lastSwitchAt = try values.decodeIfPresent(Date.self, forKey: .lastSwitchAt)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        completedRecoveryKeys = try values.decodeIfPresent(Set<String>.self, forKey: .completedRecoveryKeys) ?? []
        failedRecoveryKeys = try values.decodeIfPresent(Set<String>.self, forKey: .failedRecoveryKeys)
        lastSnapshot = try values.decodeIfPresent(SwitchSnapshot.self, forKey: .lastSnapshot)
        nextQuotaProfileIndex = try values.decodeIfPresent(Int.self, forKey: .nextQuotaProfileIndex)
        pendingSwitch = try values.decodeIfPresent(SwitchTransaction.self, forKey: .pendingSwitch)
    }
}

struct RelayRuntimeStatus: Codable, Equatable, Sendable {
    var updatedAt: Date
    var activeProfile: String?
    var primaryUsedPercent: Int?
    var secondaryUsedPercent: Int?
    var planType: String?
    var message: String
}

struct AccountQuotaStatus: Codable, Equatable, Sendable {
    var profile: String
    var updatedAt: Date
    var primary: RateLimitWindow?
    var secondary: RateLimitWindow?
    var planType: String?
    var error: String?
    var duplicateOf: String?
    var lastAttemptAt: Date
    var consecutiveAuthenticationFailures: Int

    init(profile: String, updatedAt: Date, primary: RateLimitWindow?, secondary: RateLimitWindow?,
         planType: String?, error: String?, duplicateOf: String? = nil,
         lastAttemptAt: Date? = nil, consecutiveAuthenticationFailures: Int = 0) {
        self.profile = profile
        self.updatedAt = updatedAt
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.error = error
        self.duplicateOf = duplicateOf
        self.lastAttemptAt = lastAttemptAt ?? updatedAt
        self.consecutiveAuthenticationFailures = consecutiveAuthenticationFailures
    }

    private enum CodingKeys: String, CodingKey {
        case profile, updatedAt, primary, secondary, planType, error, duplicateOf
        case lastAttemptAt, consecutiveAuthenticationFailures
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        self.init(
            profile: try values.decode(String.self, forKey: .profile),
            updatedAt: updatedAt,
            primary: try values.decodeIfPresent(RateLimitWindow.self, forKey: .primary),
            secondary: try values.decodeIfPresent(RateLimitWindow.self, forKey: .secondary),
            planType: try values.decodeIfPresent(String.self, forKey: .planType),
            error: try values.decodeIfPresent(String.self, forKey: .error),
            duplicateOf: try values.decodeIfPresent(String.self, forKey: .duplicateOf),
            lastAttemptAt: try values.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
                ?? updatedAt,
            consecutiveAuthenticationFailures: try values.decodeIfPresent(
                Int.self, forKey: .consecutiveAuthenticationFailures) ?? 0
        )
    }
}

struct AccountQuotaCollection: Codable, Equatable, Sendable {
    var accounts: [String: AccountQuotaStatus] = [:]
}

enum RelayError: LocalizedError {
    case invalidArguments(String)
    case missingFile(String)
    case invalidProfile(String)
    case rpc(String)
    case verification(String)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .missingFile(let message), .invalidProfile(let message),
             .rpc(let message), .verification(let message), .process(let message): message
        }
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([JSONValue].self) { self = .array(result) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .string(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .bool(let result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }

    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var int: Int? { if case .number(let value) = self { Int(value) } else { nil } }
    var int64: Int64? { if case .number(let value) = self { Int64(value) } else { nil } }
}
