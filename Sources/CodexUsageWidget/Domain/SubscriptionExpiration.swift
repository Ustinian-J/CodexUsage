import Foundation

enum SubscriptionExpirationStatus: Equatable {
    case unconfigured
    case active(daysRemaining: Int)
    case expiresToday
    case expired(daysAgo: Int)
}

enum SubscriptionExpiration {
    static func status(
        enabled: Bool,
        expirationDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SubscriptionExpirationStatus {
        guard enabled else { return .unconfigured }
        let today = calendar.startOfDay(for: now)
        let expirationDay = calendar.startOfDay(for: expirationDate)
        let distance = calendar.dateComponents([.day], from: today, to: expirationDay).day ?? 0
        if distance > 0 { return .active(daysRemaining: distance) }
        if distance == 0 { return .expiresToday }
        return .expired(daysAgo: -distance)
    }
}
