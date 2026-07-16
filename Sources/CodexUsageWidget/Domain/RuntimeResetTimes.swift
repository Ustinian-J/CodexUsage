import Foundation

enum RuntimeResetWindow: Equatable {
    case fiveHour
    case sevenDay

    var shortLabel: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .sevenDay:
            return "7d"
        }
    }
}

struct RuntimeResetTimeRow: Equatable {
    let window: RuntimeResetWindow
    let resetsAt: Date?
}

struct RuntimeResetTimes: Equatable {
    let rows: [RuntimeResetTimeRow]

    init(fiveHourQuota: RateWindow?, sevenDayQuota: RateWindow?) {
        rows = [
            RuntimeResetTimeRow(window: .fiveHour, resetsAt: fiveHourQuota?.resetsAt),
            RuntimeResetTimeRow(window: .sevenDay, resetsAt: sevenDayQuota?.resetsAt)
        ]
    }
}
