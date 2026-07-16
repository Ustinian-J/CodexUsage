import SwiftUI

struct RuntimeSelector: View {
    @Environment(\.colorScheme) private var colorScheme
    let selected: RuntimeScope
    let scopes: [RuntimeScope]
    let language: WidgetLanguage
    let onSelect: (RuntimeScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(scopes) { scope in
                Button {
                    onSelect(scope)
                } label: {
                    HStack(spacing: 5) {
                        RuntimeLogoView(scope: scope, size: 15)
                        Text(label(for: scope))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .foregroundStyle(selected == scope ? .primary : .secondary)
                    .frame(minWidth: scope == .claudeCode ? 112 : 78, minHeight: titlebarControlHeight)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected == scope ? WidgetPalette.controlSelectedFill(colorScheme) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help(label(for: scope))
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(WidgetPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(WidgetPalette.controlStroke(colorScheme), lineWidth: 0.8)
                )
        )
    }

    private func label(for scope: RuntimeScope) -> String {
        switch scope {
        case .codex:
            return "Codex"
        case .claudeCode:
            return language.text("Claude Code", "Claude Code")
        }
    }
}

struct RuntimeStatusMenuView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    let openRuntime: (RuntimeScope) -> Void
    let openCurrent: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    private var language: WidgetLanguage { settings.language }
    private var displayedScopes: [RuntimeScope] { settings.visibleRuntimeScopes }
    private var selectedScope: RuntimeScope {
        RuntimeStatusMenuPolicy.selectedScope(
            preferred: store.selectedRuntimeScope,
            visibleScopes: displayedScopes
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            RuntimeSelector(
                selected: selectedScope,
                scopes: displayedScopes,
                language: language
            ) { scope in
                store.selectRuntime(scope)
            }
            RuntimeSummaryCard(
                summary: summary(for: selectedScope),
                isSelected: true,
                language: language
            ) {
                openRuntime(selectedScope)
            }
            if RuntimeStatusMenuPolicy.showsCodexAccountDetails(for: selectedScope) {
                quotaResetTimesRow
                accountCycleRow
            }
            footer
        }
        .padding(14)
        .frame(width: 380, height: runtimeStatusPopoverHeight(for: 1), alignment: .top)
        .readableForegroundHierarchy(colorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("CodexUsage")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(selectedScope.displayName) · \(language.text("刷新", "Refreshed")) \(runtimeTimeOnly(store.snapshot.refreshedAt))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: store.isRefreshing ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help(language.text("刷新", "Refresh"))
        }
    }

    private var accountCycleRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                compactCycleValue(
                    title: language.text("可用重置", "Resets"),
                    value: resetCount.map { String($0) } ?? "--"
                )
                Divider().frame(height: 14)
                compactCycleValue(
                    title: language.text("最近到期", "Next expiry"),
                    value: nextResetExpiry.map(runtimeCompactDateTime) ?? "--"
                )
            }
            if RuntimeStatusMenuPolicy.showsSubscriptionExpiration(
                for: selectedScope,
                isLocallyConfigured: settings.subscriptionExpirationEnabled
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(language.text("订阅到期", "Subscription"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(subscriptionSummary)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WidgetPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(WidgetPalette.controlStroke(colorScheme), lineWidth: 0.8)
                )
        )
    }

    private var quotaResetTimesRow: some View {
        VStack(spacing: 0) {
            ForEach(Array(resetTimes.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider()
                        .padding(.leading, 34)
                        .padding(.vertical, 5)
                }
                HStack(spacing: 8) {
                    Text(row.window.shortLabel)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(resetRowTint(row.window))
                        .frame(width: 26, height: 18)
                        .background(
                            Capsule(style: .continuous)
                                .fill(resetRowTint(row.window).opacity(0.13))
                        )
                    Text(language.text("下次重置", "Next reset"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.resetsAt.map(runtimeCompactDateTime) ?? "--")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WidgetPalette.controlFill(colorScheme))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(WidgetPalette.controlStroke(colorScheme), lineWidth: 0.8)
                )
        )
    }

    private func compactCycleValue(title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var codexSnapshot: UsageSnapshot? {
        store.runtimeSnapshot(for: .codex)?.snapshot
    }

    private var resetTimes: RuntimeResetTimes {
        RuntimeResetTimes(
            fiveHourQuota: codexSnapshot?.fiveHourQuota,
            sevenDayQuota: codexSnapshot?.sevenDayQuota
        )
    }

    private func resetRowTint(_ window: RuntimeResetWindow) -> Color {
        switch window {
        case .fiveHour:
            return WidgetPalette.brandPrimary
        case .sevenDay:
            return WidgetPalette.brandSecondary
        }
    }

    private var resetCount: Int? {
        codexSnapshot?.credits?.resetCredits?.availableCount
    }

    private var nextResetExpiry: Date? {
        let now = Date()
        return codexSnapshot?.credits?.resetCredits?.credits
            .compactMap(\.expiresAt)
            .filter { $0 > now }
            .min()
    }

    private var subscriptionSummary: String {
        let status = SubscriptionExpiration.status(
            enabled: settings.subscriptionExpirationEnabled,
            expirationDate: settings.subscriptionExpirationDate
        )
        switch status {
        case .unconfigured:
            return language.text("未设置（设置中记录）", "Not set (configure in Settings)")
        case .active(let daysRemaining):
            return language.text(
                "\(accountDateOnly(settings.subscriptionExpirationDate, language: language)) · \(daysRemaining) 天",
                "\(accountDateOnly(settings.subscriptionExpirationDate, language: language)) · \(daysRemaining)d"
            )
        case .expiresToday:
            return language.text("今天到期", "Expires today")
        case .expired(let daysAgo):
            return language.text("已过期 \(daysAgo) 天", "Expired \(daysAgo)d ago")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            menuCommandButton(
                title: language.text("打开主界面", "Open Main Window"),
                systemName: "rectangle.on.rectangle",
                action: openCurrent
            )
            menuCommandButton(
                title: language.text("设置", "Settings"),
                systemName: "gearshape",
                action: openSettings
            )
            menuCommandButton(
                title: language.text("退出", "Quit"),
                systemName: "power",
                action: quit
            )
        }
    }

    private func menuCommandButton(title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WidgetPalette.controlFill(colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(WidgetPalette.controlStroke(colorScheme), lineWidth: 0.8)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func summary(for scope: RuntimeScope) -> RuntimeMenuSummary {
        store.runtimeSnapshot(for: scope)?.summary ?? RuntimeMenuSummary(
            scope: scope,
            displayName: scope.displayName,
            status: .unavailable,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: nil,
            sevenDayResetsAt: nil,
            todayTokens: nil,
            sourceLabel: language.text("等待本机统计", "Waiting for local records")
        )
    }
}

struct RuntimeSummaryCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let summary: RuntimeMenuSummary
    let isSelected: Bool
    let language: WidgetLanguage
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 8) {
                    RuntimeLogoView(scope: summary.scope, size: 24)
                    Text(summary.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(summary.status.localized(language))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(statusTint.opacity(0.16))
                        )
                        .foregroundStyle(statusTint)
                }

                HStack(spacing: 10) {
                    if quotaItems.isEmpty {
                        quotaUnavailableColumn
                    } else {
                        ForEach(quotaItems) { item in
                            quotaColumn(item, width: quotaColumnWidth)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("今日 token", "Today"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(TokenFormatter.format(summary.todayTokens))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 82, alignment: .leading)
                }

                Text(localizedSourceLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? selectedFill : WidgetPalette.cardFill(colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? selectedStroke : WidgetPalette.cardStroke(colorScheme), lineWidth: 0.9)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(language.text("打开 \(summary.displayName)", "Open \(summary.displayName)"))
    }

    private var quotaItems: [RuntimeQuotaSummaryItem] {
        var items: [RuntimeQuotaSummaryItem] = []
        if let value = summary.fiveHourRemainingPercent {
            items.append(RuntimeQuotaSummaryItem(
                id: "five-hour",
                title: language.text("5小时剩余", "5h left"),
                value: value,
                resetsAt: summary.fiveHourResetsAt
            ))
        }
        if let value = summary.sevenDayRemainingPercent {
            items.append(RuntimeQuotaSummaryItem(
                id: "seven-day",
                title: language.text("7日剩余", "7d left"),
                value: value,
                resetsAt: summary.sevenDayResetsAt
            ))
        }
        return items
    }

    private var quotaColumnWidth: CGFloat {
        quotaItems.count == 1 ? 182 : 86
    }

    private func quotaColumn(_ item: RuntimeQuotaSummaryItem, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(runtimeFormatPercent(item.value))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(WidgetPalette.surfaceTrack)
                    Capsule(style: .continuous)
                        .fill(statusTint.opacity(0.72))
                        .frame(width: proxy.size.width * CGFloat(max(0, min(100, item.value)) / 100))
                }
            }
            .frame(height: 4)
            Text(item.resetsAt.map { runtimeTimeOnly($0) } ?? "--")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(width: width, alignment: .leading)
    }

    private var quotaUnavailableColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(language.text("额度", "Quota"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Image(systemName: quotaUnavailableSystemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusTint)
                Text(quotaUnavailableTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Text(quotaUnavailableDetail)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(width: 182, alignment: .leading)
    }

    private var quotaUnavailableTitle: String {
        switch summary.status {
        case .available:
            return language.text("当前无额度限制", "No active quota limits")
        case .localOnly:
            return language.text("暂无额度数据", "No quota data")
        case .snapshotNeeded:
            return language.text("需要额度快照", "Quota snapshot needed")
        case .stale:
            return language.text("额度快照已过期", "Quota snapshot is stale")
        case .unavailable:
            return language.text("额度暂不可用", "Quota unavailable")
        }
    }

    private var quotaUnavailableDetail: String {
        switch summary.status {
        case .available:
            return language.text("服务端未返回活动额度窗口", "No active quota window was returned")
        case .localOnly:
            return language.text("当前仅显示本机统计", "Showing local records only")
        case .snapshotNeeded:
            return language.text("打开 Runtime 后刷新", "Open the runtime, then refresh")
        case .stale:
            return language.text("打开 Runtime 获取最新快照", "Open the runtime for a fresh snapshot")
        case .unavailable:
            return language.text("请检查登录状态或数据源", "Check sign-in and the data source")
        }
    }

    private var quotaUnavailableSystemName: String {
        switch summary.status {
        case .available:
            return "checkmark.circle"
        case .snapshotNeeded:
            return "waveform.path.ecg"
        case .stale:
            return "clock.badge.exclamationmark"
        case .localOnly:
            return "info.circle"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch summary.status {
        case .available:
            return WidgetPalette.statusSuccess
        case .localOnly, .snapshotNeeded:
            return WidgetPalette.statusWarning
        case .stale:
            return WidgetPalette.statusInfo
        case .unavailable:
            return WidgetPalette.statusDanger
        }
    }

    private var selectedFill: Color {
        WidgetPalette.brandPrimary.opacity(colorScheme == .dark ? 0.20 : 0.12)
    }

    private var selectedStroke: Color {
        WidgetPalette.brandPrimary.opacity(colorScheme == .dark ? 0.42 : 0.34)
    }

    private var localizedSourceLabel: String {
        let hasQuota = summary.fiveHourRemainingPercent != nil
            || summary.sevenDayRemainingPercent != nil
        if language.isChinese {
            switch summary.scope {
            case .codex:
                if hasQuota { return "官方额度 + 本机统计" }
                return summary.status == .available
                    ? "官方额度：当前无限制 · 本机统计"
                    : "本机统计；额度暂不可用"
            case .claudeCode:
                if hasQuota {
                    return summary.status == .stale ? "过期快照 + 本机统计" : "active snapshot + 本机统计"
                }
                return "本机统计；额度需 active snapshot"
            }
        }
        switch summary.scope {
        case .codex:
            if hasQuota { return "Official quota + local records" }
            return summary.status == .available
                ? "Official quota: no active limits · local records"
                : "Local records; quota unavailable"
        case .claudeCode:
            if hasQuota {
                return summary.status == .stale ? "Stale snapshot + local records" : "Active snapshot + local records"
            }
            return "Local records; quota needs active snapshot"
        }
    }
}

private struct RuntimeQuotaSummaryItem: Identifiable {
    let id: String
    let title: String
    let value: Double
    let resetsAt: Date?
}

struct RuntimeLogoView: View {
    @Environment(\.colorScheme) private var colorScheme
    let scope: RuntimeScope
    let size: CGFloat

    var body: some View {
        Group {
            if let image = RuntimeLogo.image(for: scope) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemName)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(.secondary)
                    .background(WidgetPalette.controlFill(colorScheme))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous)
                .strokeBorder(WidgetPalette.cardStroke(colorScheme), lineWidth: 0.7)
        )
        .accessibilityHidden(true)
    }

    private var fallbackSystemName: String {
        switch scope {
        case .codex:
            return "terminal"
        case .claudeCode:
            return "curlybraces"
        }
    }
}

private enum RuntimeLogo {
    static func image(for scope: RuntimeScope) -> NSImage? {
        let name: String
        switch scope {
        case .codex:
            name = "codex-color"
        case .claudeCode:
            name = "claudecode-color"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private func runtimeFormatPercent(_ value: Double?) -> String {
    guard let value else { return "--" }
    if value > 0, value < 1 {
        return "<1%"
    }
    return "\(Int(value.rounded()))%"
}

private func runtimeTimeOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func runtimeCompactDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
    return formatter.string(from: date)
}
