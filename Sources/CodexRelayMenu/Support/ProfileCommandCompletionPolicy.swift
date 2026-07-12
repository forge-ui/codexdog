import Foundation

enum ProfileCommandCompletionPolicy {
    static func message(
        terminationStatus: Int32,
        restartError: String?,
        commandOutput: String
    ) -> String? {
        guard terminationStatus != 0 else { return restartError }

        let failure = failureDetail(in: commandOutput)
            .map { "账号操作失败：\($0)" }
            ?? "账号操作失败"
        guard let restartError, !restartError.isEmpty else { return failure }
        return "\(failure)；看门狗重启失败：\(restartError)"
    }

    private static func failureDetail(in output: String) -> String? {
        let candidates = output.split(whereSeparator: \.isNewline).reversed()
        for candidate in candidates {
            var line = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.lowercased().hasPrefix("codex-relay:") {
                line = String(line.dropFirst("codex-relay:".count))
                    .trimmingCharacters(in: .whitespaces)
                return String(line.prefix(140))
            }
            let lowercased = line.lowercased()
            if lowercased.contains("error")
                || lowercased.contains("failed")
                || lowercased.contains("invalid") {
                return String(line.prefix(140))
            }
        }
        return nil
    }
}
