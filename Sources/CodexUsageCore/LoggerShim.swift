import Foundation

/// The embedded scanner intentionally does not emit session paths or identifiers.
struct CodexUsageLogger: Sendable {
    func debug(_ message: String, metadata: [String: String]? = nil) {}
    func warning(_ message: String, metadata: [String: String]? = nil) {}
}

enum CodexBarLog {
    static func logger(_ category: String) -> CodexUsageLogger { CodexUsageLogger() }
}

enum LogCategories {
    static let tokenCost = "token-cost"
}
