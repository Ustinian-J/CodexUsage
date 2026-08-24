import SwiftUI

struct TaskActivityCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: CodexTaskActivityStore
    let language: WidgetLanguage

    private var snapshot: CodexTaskActivitySnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                TaskTrafficLightView(snapshot: snapshot)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.text("任务动态", "Task activity"))
                        .font(.system(size: 11, weight: .bold))
                    Text(statusText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.unreadCount > 0 {
                    Button(language.text("全部已读", "Mark all read")) {
                        store.markAllRead()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WidgetPalette.statusWarning)
                }
            }

            if snapshot.runningCount > 0 || snapshot.unreadCount > 0 {
                activitySummary
            }

            switch snapshot.availability {
            case .starting:
                compactMessage(
                    icon: "hourglass",
                    text: language.text("正在连接 Codex 本机与远程任务记录…", "Connecting to local and remote Codex task records…")
                )
            case let .connecting(attempt, maximum):
                compactMessage(
                    icon: "network",
                    text: language.text(
                        "正在恢复远程监听（退避级别 \(attempt)/\(maximum)）…",
                        "Restoring remote monitoring (backoff level \(attempt)/\(maximum))…"
                    )
                )
            case let .unavailable(message):
                compactMessage(
                    icon: "exclamationmark.triangle",
                    text: language.text(message, "Task monitoring is temporarily unavailable")
                )
            case .ready:
                if snapshot.runningCount == 0, snapshot.unreadCount == 0 {
                    activitySummary
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(WidgetPalette.cardFill(colorScheme, elevated: true))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(WidgetPalette.cardStroke(colorScheme, elevated: true), lineWidth: 0.9)
                )
        )
    }

    private var activitySummary: some View {
        compactMessage(icon: activityIcon, text: activityText)
    }

    private var activityIcon: String {
        if snapshot.runningCount > 0 { return "gearshape.2" }
        if snapshot.unreadCount > 0 { return "bell.badge" }
        return "checkmark.circle"
    }

    private var activityText: String {
        if snapshot.runningCount > 0, snapshot.unreadCount > 0 {
            return language.text(
                "\(snapshot.runningCount) 个任务执行中 · \(snapshot.unreadCount) 个任务已完成待查看",
                "\(snapshot.runningCount) running · \(snapshot.unreadCount) completed and unread"
            )
        }
        if snapshot.runningCount > 0 {
            return language.text(
                "\(snapshot.runningCount) 个任务正在执行",
                "\(snapshot.runningCount) task(s) running"
            )
        }
        if snapshot.unreadCount > 0 {
            return language.text(
                "\(snapshot.unreadCount) 个任务已完成，等待查看",
                "\(snapshot.unreadCount) completed task(s) waiting to be viewed"
            )
        }
        return language.text("当前空闲，没有未读完成提醒", "Idle with no unread completions")
    }

    private func compactMessage(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(WidgetPalette.controlFill(colorScheme))
        )
    }

    private var statusText: String {
        switch snapshot.availability {
        case .starting:
            return language.text("正在启动", "Starting")
        case let .connecting(attempt, maximum):
            return language.text(
                "远程监听恢复中 · 退避级别 \(attempt)/\(maximum)",
                "Restoring remote monitoring · backoff level \(attempt)/\(maximum)"
            )
        case .unavailable:
            return language.text("监控不可用", "Monitor unavailable")
        case .ready:
            let source = snapshot.remoteHosts.isEmpty || !snapshot.remoteMonitoringEnabled
                ? language.text("本机", "Local")
                : language.text(
                    "本机 + \(snapshot.remoteHosts.count) 远程配置",
                    "Local + \(snapshot.remoteHosts.count) remote configured"
                )
            return language.text(
                "\(source) · \(snapshot.runningCount) 个执行中 · \(snapshot.unreadCount) 条新完成",
                "\(source) · \(snapshot.runningCount) running · \(snapshot.unreadCount) new"
            )
        }
    }
}

private struct TaskTrafficLightView: View {
    let snapshot: CodexTaskActivitySnapshot

    var body: some View {
        VStack(spacing: 2) {
            light(WidgetPalette.statusDanger, active: snapshot.showsRed)
            light(WidgetPalette.statusWarning, active: snapshot.showsYellow)
            light(WidgetPalette.statusSuccess, active: snapshot.showsGreen)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Task status")
    }

    private func light(_ color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : Color.secondary.opacity(0.20))
            .frame(width: 6, height: 6)
            .shadow(color: active ? color.opacity(0.38) : .clear, radius: 2)
    }
}
