import Foundation

enum RateLimitResetCreditStatus: String, Equatable {
    case available
    case redeeming
    case redeemed
    case unknown

    init(serverValue: String?) {
        self = serverValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

struct RateLimitResetCredit: Identifiable, Equatable {
    let id: String
    let title: String?
    let detail: String?
    let grantedAt: Date
    let expiresAt: Date?
    let resetType: String
    let status: RateLimitResetCreditStatus
}

struct RateLimitResetCredits: Equatable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]
    let detailsProvided: Bool

    static func parse(_ value: Any?) -> RateLimitResetCredits? {
        guard let object = value as? [String: Any],
              let availableCount = integer(object["availableCount"]),
              availableCount >= 0 else {
            return nil
        }

        let rawCredits = object["credits"]
        let detailsProvided = rawCredits is [[String: Any]] || rawCredits is [Any]
        let rows = rawCredits as? [Any] ?? []
        let credits = rows.compactMap(parseCredit)

        return RateLimitResetCredits(
            availableCount: availableCount,
            credits: credits,
            detailsProvided: detailsProvided
        )
    }

    private static func parseCredit(_ value: Any) -> RateLimitResetCredit? {
        guard let object = value as? [String: Any],
              let id = object["id"] as? String,
              !id.isEmpty,
              let grantedAt = epochDate(object["grantedAt"]),
              let resetType = object["resetType"] as? String else {
            return nil
        }

        return RateLimitResetCredit(
            id: id,
            title: nonEmptyString(object["title"]),
            detail: nonEmptyString(object["description"]),
            grantedAt: grantedAt,
            expiresAt: epochDate(object["expiresAt"]),
            resetType: resetType,
            status: RateLimitResetCreditStatus(serverValue: object["status"] as? String)
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? Double, value.isFinite { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func epochDate(_ value: Any?) -> Date? {
        let seconds: Double?
        if let value = value as? Int {
            seconds = Double(value)
        } else if let value = value as? Int64 {
            seconds = Double(value)
        } else if let value = value as? Double {
            seconds = value
        } else if let value = value as? String {
            seconds = Double(value)
        } else {
            seconds = nil
        }
        guard var seconds, seconds.isFinite, seconds > 0 else { return nil }
        if seconds > 10_000_000_000 { seconds /= 1_000 }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
