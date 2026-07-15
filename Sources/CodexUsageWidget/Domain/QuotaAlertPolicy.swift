import Foundation

enum QuotaAlertWindowKind: String, Equatable {
    case fiveHour
    case sevenDay
}

struct QuotaAlertDecision: Equatable {
    let notificationThreshold: Int?
    let recordedThresholds: Set<Int>
}

enum QuotaAlertPolicy {
    static let thresholds = [20, 10, 5]

    static func evaluate(
        enabled: Bool,
        remainingPercent: Double?,
        previouslyRecorded: Set<Int>
    ) -> QuotaAlertDecision {
        guard enabled, let remainingPercent, remainingPercent.isFinite else {
            return QuotaAlertDecision(
                notificationThreshold: nil,
                recordedThresholds: previouslyRecorded
            )
        }

        let remaining = min(max(remainingPercent, 0), 100)
        let crossed = Set(thresholds.filter { remaining <= Double($0) })
        let newlyCrossed = crossed.subtracting(previouslyRecorded)

        return QuotaAlertDecision(
            notificationThreshold: newlyCrossed.min(),
            recordedThresholds: previouslyRecorded.union(crossed)
        )
    }

    static func recordedThresholds(
        storedCycle: String?,
        currentCycle: String,
        storedThresholds: Set<Int>
    ) -> Set<Int> {
        storedCycle == currentCycle ? storedThresholds : []
    }
}
