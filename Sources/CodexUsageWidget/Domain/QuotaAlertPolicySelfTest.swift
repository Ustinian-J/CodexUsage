import Foundation

enum QuotaAlertPolicySelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let disabled = QuotaAlertPolicy.evaluate(
            enabled: false,
            remainingPercent: 19,
            previouslyRecorded: []
        )
        expect(disabled.notificationThreshold == nil, "alerts must default to no notification when disabled")
        expect(disabled.recordedThresholds.isEmpty, "disabled evaluation must not consume a threshold")

        let suiteName = "CodexUsage.QuotaAlertPolicySelfTest.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let initialSettings = AppSettings(defaults: defaults)
            expect(!initialSettings.quotaAlertsEnabled, "quota alerts must be off by default")
            initialSettings.quotaAlertsEnabled = true
            let reloadedSettings = AppSettings(defaults: defaults)
            expect(reloadedSettings.quotaAlertsEnabled, "the explicit alert setting should persist")
        } else {
            failures.append("could not create isolated defaults for alert settings")
        }

        let first = QuotaAlertPolicy.evaluate(
            enabled: true,
            remainingPercent: 19,
            previouslyRecorded: []
        )
        expect(first.notificationThreshold == 20, "crossing 20 percent should notify once")
        expect(first.recordedThresholds == [20], "the 20 percent threshold should be recorded")

        let repeated = QuotaAlertPolicy.evaluate(
            enabled: true,
            remainingPercent: 18,
            previouslyRecorded: first.recordedThresholds
        )
        expect(repeated.notificationThreshold == nil, "repeated refreshes must not notify again")

        let lower = QuotaAlertPolicy.evaluate(
            enabled: true,
            remainingPercent: 9,
            previouslyRecorded: first.recordedThresholds
        )
        expect(lower.notificationThreshold == 10, "crossing 10 percent should notify")
        expect(lower.recordedThresholds == [20, 10], "both crossed thresholds should be recorded")

        let coldStartAtFour = QuotaAlertPolicy.evaluate(
            enabled: true,
            remainingPercent: 4,
            previouslyRecorded: []
        )
        expect(coldStartAtFour.notificationThreshold == 5, "a low cold start should emit only the most urgent alert")
        expect(coldStartAtFour.recordedThresholds == [20, 10, 5], "a low cold start should suppress later stale alerts")

        let resetThresholds = QuotaAlertPolicy.recordedThresholds(
            storedCycle: "old-reset",
            currentCycle: "new-reset",
            storedThresholds: [20, 10, 5]
        )
        expect(resetThresholds.isEmpty, "a new reset cycle should clear recorded thresholds")
        let newCycle = QuotaAlertPolicy.evaluate(
            enabled: true,
            remainingPercent: 19,
            previouslyRecorded: resetThresholds
        )
        expect(newCycle.notificationThreshold == 20, "a new reset cycle should allow thresholds again")

        if failures.isEmpty {
            print("quota alert policy self-test passed")
            return true
        }
        for failure in failures {
            fputs("quota alert policy self-test failed: \(failure)\n", stderr)
        }
        return false
    }
}
