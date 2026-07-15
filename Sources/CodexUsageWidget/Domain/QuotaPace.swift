import Foundation

enum QuotaPaceStatus: String, Equatable {
    case comfortable
    case onPace
    case fast
    case unavailable
}

struct QuotaPace: Equatable {
    let status: QuotaPaceStatus
    let elapsedFraction: Double?
    let usedFraction: Double?

    static func calculate(window: RateWindow?, now: Date, tolerance: Double = 0.10) -> QuotaPace {
        guard let window,
              let durationMins = window.windowDurationMins,
              durationMins > 0,
              let resetsAt = window.resetsAt else {
            return QuotaPace(status: .unavailable, elapsedFraction: nil, usedFraction: nil)
        }

        let duration = Double(durationMins) * 60
        let startedAt = resetsAt.addingTimeInterval(-duration)
        guard now >= startedAt, now <= resetsAt else {
            return QuotaPace(status: .unavailable, elapsedFraction: nil, usedFraction: nil)
        }
        let elapsed = min(max(now.timeIntervalSince(startedAt) / duration, 0), 1)
        let used = min(max(window.usedPercent / 100, 0), 1)
        let margin = max(tolerance, 0)
        let status: QuotaPaceStatus

        if used < elapsed - margin {
            status = .comfortable
        } else if used > elapsed + margin {
            status = .fast
        } else {
            status = .onPace
        }

        return QuotaPace(status: status, elapsedFraction: elapsed, usedFraction: used)
    }
}
