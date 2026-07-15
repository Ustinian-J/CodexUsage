import Foundation

enum RateLimitResetCreditsSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let fixture: [String: Any] = [
            "availableCount": 3,
            "credits": [
                [
                    "id": "reset-1",
                    "title": "Codex reset",
                    "description": "One extra reset",
                    "grantedAt": 1_800_000_000,
                    "expiresAt": 1_800_086_400,
                    "resetType": "codexRateLimits",
                    "status": "available"
                ],
                [
                    "id": "reset-2",
                    "grantedAt": 1_800_100_000,
                    "expiresAt": NSNull(),
                    "resetType": "unknown",
                    "status": "redeeming"
                ]
            ]
        ]

        guard let summary = RateLimitResetCredits.parse(fixture) else {
            failures.append("valid reset-credit summary must parse")
            return finish(failures)
        }

        expect(summary.availableCount == 3, "available count must preserve the backend value")
        expect(summary.detailsProvided, "a credits array must be distinguishable from omitted details")
        expect(summary.credits.count == 2, "every valid detail row must be retained")
        expect(summary.credits.first?.id == "reset-1", "opaque backend id must be preserved")
        expect(summary.credits.first?.expiresAt == Date(timeIntervalSince1970: 1_800_086_400), "expiry must parse as epoch seconds")
        expect(summary.credits.last?.expiresAt == nil, "a non-expiring credit must keep a nil expiry")
        expect(summary.credits.last?.status == .redeeming, "known status values must be normalized")

        let countOnly = RateLimitResetCredits.parse(["availableCount": 5, "credits": NSNull()])
        expect(countOnly?.availableCount == 5, "count-only payload must remain useful")
        expect(countOnly?.detailsProvided == false, "null details must not be reported as an empty fetched list")
        expect(countOnly?.credits.isEmpty == true, "count-only payload must not invent rows")

        let empty = RateLimitResetCredits.parse(["availableCount": 0, "credits": []])
        expect(empty?.detailsProvided == true, "an explicit empty list means details were fetched")
        expect(empty?.credits.isEmpty == true, "explicit empty details must stay empty")

        expect(RateLimitResetCredits.parse(["credits": []]) == nil, "missing availableCount must reject the summary")
        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Bool {
        if failures.isEmpty {
            print("rate-limit reset credits self-test passed")
            return true
        }
        failures.forEach { fputs("rate-limit reset credits self-test failed: \($0)\n", stderr) }
        return false
    }
}
