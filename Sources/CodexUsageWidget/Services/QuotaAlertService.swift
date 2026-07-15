import Foundation
import UserNotifications

final class QuotaAlertService {
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter

    init(
        defaults: UserDefaults = .standard,
        center: UNUserNotificationCenter = .current()
    ) {
        self.defaults = defaults
        self.center = center
    }

    func updateAuthorization(enabled: Bool) {
        guard enabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                debugLog("quota alert authorization failed: \(error.localizedDescription)")
            } else if !granted {
                debugLog("quota alert authorization denied")
            }
        }
    }

    func evaluate(snapshot: UsageSnapshot, enabled: Bool, language: WidgetLanguage) {
        guard enabled, snapshot.quotaReadSucceeded else { return }
        evaluate(
            kind: .fiveHour,
            label: "5h",
            window: snapshot.fiveHourQuota,
            language: language
        )
        evaluate(
            kind: .sevenDay,
            label: "7d",
            window: snapshot.sevenDayQuota,
            language: language
        )
    }

    private func evaluate(
        kind: QuotaAlertWindowKind,
        label: String,
        window: RateWindow?,
        language: WidgetLanguage
    ) {
        guard let window, let resetsAt = window.resetsAt, resetsAt > Date() else { return }

        let cycle = String(Int64(resetsAt.timeIntervalSince1970.rounded()))
        let cycleKey = storageKey(kind: kind, suffix: "cycle")
        let thresholdsKey = storageKey(kind: kind, suffix: "thresholds")
        let storedThresholds = Set((defaults.array(forKey: thresholdsKey) ?? []).compactMap { value -> Int? in
            if let value = value as? Int { return value }
            return (value as? NSNumber)?.intValue
        })
        let recorded = QuotaAlertPolicy.recordedThresholds(
            storedCycle: defaults.string(forKey: cycleKey),
            currentCycle: cycle,
            storedThresholds: storedThresholds
        )
        let decision = QuotaAlertPolicy.evaluate(
            enabled: true,
            remainingPercent: window.remainingPercent,
            previouslyRecorded: recorded
        )

        defaults.set(cycle, forKey: cycleKey)
        defaults.set(decision.recordedThresholds.sorted(by: >), forKey: thresholdsKey)

        guard let threshold = decision.notificationThreshold else { return }
        sendNotification(
            kind: kind,
            label: label,
            remainingPercent: window.remainingPercent,
            resetsAt: resetsAt,
            threshold: threshold,
            cycle: cycle,
            language: language
        )
    }

    private func sendNotification(
        kind: QuotaAlertWindowKind,
        label: String,
        remainingPercent: Double,
        resetsAt: Date,
        threshold: Int,
        cycle: String,
        language: WidgetLanguage
    ) {
        let remaining = Int(remainingPercent.rounded())
        let reset = quotaAlertResetFormatter.string(from: resetsAt)
        let content = UNMutableNotificationContent()
        content.title = language.text("Codex \(label) 额度提醒", "Codex \(label) quota alert")
        content.body = language.text(
            "剩余 \(remaining)% · \(reset) 重置",
            "\(remaining)% remaining · resets \(reset)"
        )
        content.sound = .default

        let identifier = "CodexUsage.quota.\(kind.rawValue).\(cycle).\(threshold)"
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                debugLog("quota alert delivery failed: \(error.localizedDescription)")
            }
        }
    }

    private func storageKey(kind: QuotaAlertWindowKind, suffix: String) -> String {
        "CodexUsage.quotaAlerts.\(kind.rawValue).\(suffix)"
    }
}

private let quotaAlertResetFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()
