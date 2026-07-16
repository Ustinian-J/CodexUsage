import Foundation

enum RuntimeResetTimesSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let fiveHourDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sevenDayDate = Date(timeIntervalSince1970: 1_800_100_000)
        let summary = RuntimeResetTimes(
            fiveHourQuota: RateWindow(usedPercent: 25, windowDurationMins: 300, resetsAt: fiveHourDate),
            sevenDayQuota: RateWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: sevenDayDate)
        )
        expect(summary.rows.map(\.window) == [.fiveHour, .sevenDay], "reset rows must stay in 5h then 7d order")
        expect(summary.rows.map(\.resetsAt) == [fiveHourDate, sevenDayDate], "each row must preserve its own reset time")

        let missingFiveHour = RuntimeResetTimes(
            fiveHourQuota: nil,
            sevenDayQuota: RateWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: sevenDayDate)
        )
        expect(missingFiveHour.rows.count == 2, "missing quota data must not collapse the two-row layout")
        expect(missingFiveHour.rows[0].resetsAt == nil, "missing 5h data must stay unavailable")
        expect(missingFiveHour.rows[1].resetsAt == sevenDayDate, "7d data must remain on the 7d row")

        if failures.isEmpty {
            print("runtime reset times self-test passed")
            return true
        }
        failures.forEach { fputs("runtime reset times self-test failed: \($0)\n", stderr) }
        return false
    }
}
