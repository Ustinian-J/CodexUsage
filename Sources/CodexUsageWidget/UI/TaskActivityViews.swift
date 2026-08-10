import SwiftUI

struct TaskActivityCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: CodexTaskActivityStore
    let language: WidgetLanguage
    let onOpenCodex: () -> Void

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

            switch snapshot.availability {
            case .starting:
                compactMessage(
                    icon: "hourglass",
                    text: language.text("正在连接 Codex 本机与远程任务记录…", "Connecting to local and remote Codex task records…")
                )
            case let .unavailable(message):
                compactMessage(
                    icon: "exclamationmark.triangle",
                    text: language.text(message, "Task monitoring is temporarily unavailable")
                )
            case .ready:
                completionContent
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

    @ViewBuilder
    private var completionContent: some View {
        let items = Array(snapshot.recentCompletions.prefix(3))
        if items.isEmpty {
            compactMessage(
                icon: snapshot.runningCount > 0 ? "gearshape.2" : "checkmark.circle",
                text: snapshot.runningCount > 0
                    ? language.text("Codex 正在处理任务，完成后会在这里提醒", "Codex is working; completed tasks will appear here")
                    : language.text("当前空闲，没有未查看的完成任务", "Idle with no unreviewed completed tasks")
            )
        } else {
            VStack(spacing: 5) {
                ForEach(items) { completion in
                    completionRow(completion)
                }
            }
            if snapshot.recentCompletions.count > items.count {
                Text(language.text(
                    "另有 \(snapshot.recentCompletions.count - items.count) 条记录",
                    "\(snapshot.recentCompletions.count - items.count) more records"
                ))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func completionRow(_ completion: CodexTaskCompletion) -> some View {
        HStack(spacing: 7) {
            Image(systemName: completion.outcome == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(completion.outcome == .completed ? WidgetPalette.statusSuccess : WidgetPalette.statusWarning)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(completion.title)
                    .font(.system(size: 9, weight: completion.readAt == nil ? .semibold : .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let sourceLabel = completion.sourceLabel {
                        Text("@\(sourceLabel)")
                    }
                    if let projectName = completion.projectName {
                        Text(projectName)
                    }
                    Text(completion.completedAt, style: .time)
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if completion.readAt == nil {
                Circle()
                    .fill(WidgetPalette.statusWarning)
                    .frame(width: 5, height: 5)
            }
            Button(completion.sourceLabel == nil
                ? language.text("已读并打开", "Read & open")
                : language.text("标为已读", "Mark read")) {
                store.markRead(completion.id)
                if completion.sourceLabel == nil { onOpenCodex() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(WidgetPalette.brandPrimary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(WidgetPalette.controlFill(colorScheme))
        )
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
        case .unavailable:
            return language.text("监控不可用", "Monitor unavailable")
        case .ready:
            let source = snapshot.remoteHosts.isEmpty
                ? language.text("本机", "Local")
                : language.text("本机 + \(snapshot.remoteHosts.count) 远程", "Local + \(snapshot.remoteHosts.count) remote")
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
