import Foundation

struct EnrollmentOutput: Equatable, Sendable {
    let cleanOutput: String
    let authorizationURL: URL?
    let authorizationCode: String?
}

enum EnrollmentOutputParser {
    static func parse(_ rawOutput: String) -> EnrollmentOutput {
        let cleanOutput = clean(rawOutput)
        return EnrollmentOutput(
            cleanOutput: cleanOutput,
            authorizationURL: authorizationURL(in: cleanOutput),
            authorizationCode: authorizationCode(in: cleanOutput)
        )
    }

    private static func clean(_ rawOutput: String) -> String {
        rawOutput
            // Normal terminal output includes the ESC byte. Re-parse the full
            // buffer on every update so a control sequence split across pipe
            // callbacks is removed as soon as it becomes complete.
            .replacingOccurrences(
                of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
            // Some command output reaches SwiftUI without the ESC byte and
            // would otherwise render fragments such as `[94m` and `[0m`.
            .replacingOccurrences(
                of: "\\[[0-9;?]*m",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func authorizationURL(in output: String) -> URL? {
        let candidates = matches(pattern: #"https?://[^\s<>\"']+"#, in: output)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}")) }
            .compactMap(URL.init(string:))

        return candidates.first {
            $0.host?.caseInsensitiveCompare("auth.openai.com") == .orderedSame
                && $0.path.hasPrefix("/codex/device")
        } ?? candidates.first
    }

    private static func authorizationCode(in output: String) -> String? {
        if let marker = output.range(of: "one-time code", options: .caseInsensitive),
           let code = firstAuthorizationCode(in: String(output[marker.upperBound...]), standaloneLineOnly: false) {
            return code
        }
        return firstAuthorizationCode(in: output, standaloneLineOnly: true)
    }

    private static func firstAuthorizationCode(in output: String, standaloneLineOnly: Bool) -> String? {
        let codePattern = #"[A-Z0-9]{4,6}-[A-Z0-9]{4,6}"#
        let pattern = standaloneLineOnly
            ? #"(?m)^[ \t]*"# + codePattern + #"[ \t]*$"#
            : #"(?<![A-Z0-9])"# + codePattern + #"(?![A-Z0-9])"#
        return matches(pattern: pattern, in: output)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(pattern: String, in input: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return expression.matches(in: input, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: input) else { return nil }
            return String(input[matchRange])
        }
    }
}
