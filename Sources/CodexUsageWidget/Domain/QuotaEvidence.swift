import Foundation

enum QuotaSource: String, Equatable {
    case rpc, localHistory, retained, unknown
}

struct QuotaEvidence: Equatable {
    static let maximumHistoricalAge: TimeInterval = 15 * 60
    let source: QuotaSource
    let queriedAt: Date
    let receivedAt: Date?
    let observedAt: Date?
    let lastOfficialSuccessAt: Date?
    let environment: String
    let accountIdentity: String?
    var failure: String?

    var label: String {
        switch source {
        case .rpc: return "官方 RPC · \(Self.time(receivedAt))"
        case .localHistory: return "本地历史 · \(Self.time(observedAt)) · 账户未验证"
        case .retained: return "上次官方结果 · \(Self.time(lastOfficialSuccessAt)) · stale"
        case .unknown: return "当前额度未确认"
        }
    }

    private static func time(_ date: Date?) -> String {
        guard let date else { return "时间未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
