import Foundation

struct AccountIdentityResolver {
    static func email(forProfile profile: String, root: URL) -> String? {
        let authURL = root
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any]
        else { return nil }

        if let idToken = tokens["id_token"] as? String,
           let claims = claims(from: idToken),
           claims["email_verified"] as? Bool != false,
           let email = normalizedEmail(claims["email"])
        {
            return email
        }

        if let accessToken = tokens["access_token"] as? String,
           let claims = claims(from: accessToken),
           claims["https://api.openai.com/profile.email_verified"] as? Bool != false,
           let email = normalizedEmail(claims["https://api.openai.com/profile.email"])
        {
            return email
        }

        return nil
    }

    private static func claims(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }

        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        encoded.append(String(repeating: "=", count: padding))

        guard let data = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claims
    }

    private static func normalizedEmail(_ value: Any?) -> String? {
        guard let email = value as? String else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@"), !normalized.contains("/") else { return nil }
        return normalized
    }
}
