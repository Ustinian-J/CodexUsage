import Foundation
import UserNotifications

final class TaskCompletionAlertService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func updateAuthorization(enabled: Bool) {
        guard enabled else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                debugLog("task completion alert authorization failed: \(error.localizedDescription)")
            } else if !granted {
                debugLog("task completion alert authorization denied")
            }
        }
    }

    func send(_ completion: CodexTaskCompletion, enabled: Bool, language: WidgetLanguage) {
        guard enabled else { return }

        let content = UNMutableNotificationContent()
        switch completion.outcome {
        case .completed:
            content.title = language.text("Codex 任务已完成", "Codex task completed")
        case .interrupted:
            content.title = language.text("Codex 任务已中断", "Codex task interrupted")
        }
        content.body = language.text(
            "打开 CodexS 查看任务动态",
            "Open CodexS to review task activity"
        )
        content.sound = .default
        content.threadIdentifier = "CodexS.task-activity"

        let request = UNNotificationRequest(
            identifier: "CodexUsage.task.\(completion.id)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                debugLog("task completion alert failed: \(error.localizedDescription)")
            }
        }
    }
}
