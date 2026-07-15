import Foundation

enum SubscriptionExpirationSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = calendar.startOfDay(for: now)

        expect(
            SubscriptionExpiration.status(enabled: false, expirationDate: today, now: now, calendar: calendar) == .unconfigured,
            "disabled local tracking must remain explicitly unconfigured"
        )
        expect(
            SubscriptionExpiration.status(
                enabled: true,
                expirationDate: calendar.date(byAdding: .day, value: 3, to: today)!,
                now: now,
                calendar: calendar
            ) == .active(daysRemaining: 3),
            "a future date must report calendar-day distance"
        )
        expect(
            SubscriptionExpiration.status(enabled: true, expirationDate: today, now: now, calendar: calendar) == .expiresToday,
            "the same calendar day must report expires today"
        )
        expect(
            SubscriptionExpiration.status(
                enabled: true,
                expirationDate: calendar.date(byAdding: .day, value: -2, to: today)!,
                now: now,
                calendar: calendar
            ) == .expired(daysAgo: 2),
            "a past date must report days since expiry"
        )

        let suiteName = "CodexUsage.SubscriptionExpirationSelfTest.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let initial = AppSettings(defaults: defaults)
            expect(!initial.subscriptionExpirationEnabled, "manual subscription tracking must default off")
            let savedDate = Date(timeIntervalSince1970: 1_900_000_000)
            initial.subscriptionExpirationDate = savedDate
            initial.subscriptionExpirationEnabled = true
            let reloaded = AppSettings(defaults: defaults)
            expect(reloaded.subscriptionExpirationEnabled, "manual subscription tracking opt-in must persist")
            expect(reloaded.subscriptionExpirationDate == savedDate, "manual subscription expiry date must persist exactly")
        } else {
            failures.append("could not create isolated defaults for subscription tracking")
        }

        if failures.isEmpty {
            print("subscription expiration self-test passed")
            return true
        }
        failures.forEach { fputs("subscription expiration self-test failed: \($0)\n", stderr) }
        return false
    }
}
