import Foundation

enum LocalUsagePresentation {
    static func compactTokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let number = Double(value)
        if number >= 1_000_000_000 {
            return String(format: "%.1fB", number / 1_000_000_000)
        }
        if number >= 1_000_000 {
            return String(format: "%.0fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.0fK", number / 1_000)
        }
        return String(value)
    }

    static func statisticsTime(
        _ timestamp: String,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date = parseISO8601(timestamp) else { return "—" }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ timestamp: String) -> Date? {
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: timestamp) {
            return date
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp)
    }
}
