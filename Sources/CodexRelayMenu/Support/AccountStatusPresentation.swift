import Foundation

enum AccountStatusPresentation {
    static func text(
        isScheduled: Bool,
        duplicateDisplayName: String?,
        quota: MenuAccountQuota?
    ) -> String {
        if !isScheduled { return "调度已关闭" }
        if let duplicateDisplayName {
            return "与 \(duplicateDisplayName) 是同一账号"
        }
        if let error = quota?.error {
            if let count = authenticationFailureCount(quota: quota, error: error) {
                if count >= QuotaPollingPolicyValues.authenticationFailureThreshold {
                    return "连续认证失败，请重新登录"
                }
                return "认证检查失败，正在重试（\(count)/\(QuotaPollingPolicyValues.authenticationFailureThreshold)）"
            }
            return "同步失败"
        }
        guard let updatedAt = quota?.updatedAt else { return "等待官方额度" }
        return "更新于 \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private static func authenticationFailureCount(
        quota: MenuAccountQuota?,
        error: String
    ) -> Int? {
        if let count = quota?.consecutiveAuthenticationFailures, count > 0 {
            return count
        }
        let detail = error.lowercased()
        let legacyAuthenticationFailure = [
            "401", "403", "unauthorized", "forbidden", "token_invalidated",
            "invalid token", "token expired", "not authenticated",
            "authentication failed", "authentication required", "login required",
            "refresh token",
        ].contains { detail.contains($0) }
        return legacyAuthenticationFailure ? 1 : nil
    }
}

private enum QuotaPollingPolicyValues {
    static let authenticationFailureThreshold = 3
}
