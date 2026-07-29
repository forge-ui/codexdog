import Foundation

enum QuotaProgressTone: Equatable {
    case critical
    case warning
    case active
    case neutral
}

enum QuotaProgressPresentation {
    static func tone(remaining: Int?, isActive: Bool) -> QuotaProgressTone {
        guard let remaining else { return .neutral }
        if remaining <= 1 { return .critical }
        if remaining <= 20 { return .warning }
        return isActive ? .active : .neutral
    }
}
