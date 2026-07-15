import Foundation

enum QuotaPaceSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(150 * 60)

        expect(
            QuotaPace.calculate(window: window(used: 30, reset: reset), now: now).status == .comfortable,
            "30 percent used halfway through should be comfortable"
        )
        expect(
            QuotaPace.calculate(window: window(used: 50, reset: reset), now: now).status == .onPace,
            "50 percent used halfway through should be on pace"
        )
        expect(
            QuotaPace.calculate(window: window(used: 80, reset: reset), now: now).status == .fast,
            "80 percent used halfway through should be fast"
        )
        expect(
            QuotaPace.calculate(window: RateWindow(usedPercent: 50, windowDurationMins: 300, resetsAt: nil), now: now).status == .unavailable,
            "missing reset time should be unavailable"
        )
        expect(
            QuotaPace.calculate(window: RateWindow(usedPercent: 50, windowDurationMins: nil, resetsAt: reset), now: now).status == .unavailable,
            "missing duration should be unavailable"
        )
        expect(
            QuotaPace.calculate(window: window(used: 50, reset: now.addingTimeInterval(-1)), now: now).status == .unavailable,
            "expired windows should not claim a pace"
        )

        if failures.isEmpty {
            print("quota pace self-test passed")
            return true
        }
        failures.forEach { fputs("quota pace self-test failed: \($0)\n", stderr) }
        return false
    }

    private static func window(used: Double, reset: Date) -> RateWindow {
        RateWindow(usedPercent: used, windowDurationMins: 300, resetsAt: reset)
    }
}
