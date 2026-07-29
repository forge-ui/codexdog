import SwiftUI
import AppKit

struct MenuContentView: View {
    @ObservedObject var store: RelayMenuStore
    @State private var showsEnrollment = false
    @State private var expandedActionsProfile: String?
    @State private var confirmingDeletionProfile: String?

    init(
        store: RelayMenuStore,
        showsEnrollment: Bool = false,
        expandedActionsProfile: String? = nil,
        confirmingDeletionProfile: String? = nil)
    {
        self.store = store
        _showsEnrollment = State(initialValue: showsEnrollment)
        _expandedActionsProfile = State(initialValue: expandedActionsProfile)
        _confirmingDeletionProfile = State(initialValue: confirmingDeletionProfile)
    }

    private var profiles: [String] { store.config?.profiles ?? [] }
    private var accountListHeight: CGFloat {
        guard !profiles.isEmpty else { return 180 }
        let groupHeight = profiles.reduce(CGFloat.zero) { height, profile in
            let rowCount = max(QuotaWindowPresentation.rows(for: store.accountQuotas[profile]).count, 1)
            return height + 70 + CGFloat(rowCount) * 59
        }
        let separators = CGFloat(max(0, profiles.count - 1)) * 22
        let actions = expandedActionsProfile == nil ? 0 : CGFloat(42)
        let topInset = CGFloat(8)
        return min(420, topInset + groupHeight + separators + actions)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsEnrollment {
                AccountEnrollmentPanel(store: store, isPresented: $showsEnrollment)
                    .transition(.opacity)
            } else {
                accountAndUsageContent
                    .transition(.opacity)
            }

            Divider()

            footer
        }
        .frame(width: 360)
        .animation(.easeInOut(duration: 0.16), value: showsEnrollment)
    }

    private var accountAndUsageContent: some View {
        Group {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if profiles.isEmpty {
                        ContentUnavailableView(
                            "还没有账号",
                            systemImage: "person.crop.circle.badge.plus",
                            description: Text("点击底部的添加账号按钮。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(Array(profiles.enumerated()), id: \.element) { index, profile in
                            AccountQuotaGroup(
                                displayName: store.displayName(for: profile),
                                duplicateDisplayName: store.accountQuotas[profile]?.duplicateOf.map(store.displayName(for:)),
                                isActive: profile == store.state?.activeProfile,
                                isScheduled: store.isProfileScheduled(profile),
                                isCommandRunning: store.commandIsRunning || store.isRefreshBusy,
                                actionsExpanded: expandedActionsProfile == profile,
                                isConfirmingDeletion: confirmingDeletionProfile == profile,
                                onToggleActions: {
                                    if expandedActionsProfile == profile {
                                        expandedActionsProfile = nil
                                        confirmingDeletionProfile = nil
                                    } else {
                                        expandedActionsProfile = profile
                                        confirmingDeletionProfile = nil
                                    }
                                },
                                onToggleScheduling: {
                                    store.setProfileScheduling(
                                        profile,
                                        enabled: !store.isProfileScheduled(profile))
                                },
                                onRequestDelete: {
                                    confirmingDeletionProfile = profile
                                },
                                onCancelDelete: {
                                    confirmingDeletionProfile = nil
                                },
                                onConfirmDelete: {
                                    store.deleteProfile(profile)
                                    expandedActionsProfile = nil
                                    confirmingDeletionProfile = nil
                                },
                                quota: store.accountQuotas[profile]
                            )

                            if index < profiles.count - 1 {
                                Divider()
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                }
                .padding(.top, profiles.isEmpty ? 0 : 8)
            }
            .defaultScrollAnchor(.top)
            .frame(height: accountListHeight)

            Divider()

            LocalUsageSummaryView(
                usage: store.localUsage,
                isLoading: store.localUsageIsLoading,
                error: store.localUsageError
            )

            if !store.visibleErrors.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(store.visibleErrors.enumerated()), id: \.offset) { _, error in
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Button {
                store.manualRefresh()
            } label: {
                refreshButtonLabel
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshBusy || store.commandIsRunning || showsEnrollment)
            .help(refreshButtonHelp)

            Spacer(minLength: 2)

            Toggle("自动切换", isOn: Binding(
                get: { store.automaticSwitchingEnabled },
                set: { store.setAutomaticSwitching($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(store.isRefreshBusy || store.commandIsRunning)

            Button {
                NSApp.activate(ignoringOtherApps: true)
                showsEnrollment.toggle()
                expandedActionsProfile = nil
                confirmingDeletionProfile = nil
            } label: {
                Image(systemName: showsEnrollment ? "xmark" : "person.badge.plus")
            }
            .buttonStyle(.plain)
            .help(showsEnrollment ? "关闭添加账号" : "添加账号")
            .disabled(store.isRefreshBusy && !showsEnrollment)

            Button {
                store.quit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var refreshButtonLabel: some View {
        switch store.refreshPhase {
        case .idle:
            Label("刷新", systemImage: "arrow.clockwise")
        case .refreshing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("刷新中")
            }
        case .succeeded:
            Label("已刷新", systemImage: "checkmark")
        case .failed:
            Label("失败", systemImage: "exclamationmark.triangle")
        }
    }

    private var refreshButtonHelp: String {
        switch store.refreshPhase {
        case .idle: "刷新官方额度和本机用量"
        case .refreshing: "正在刷新官方额度和本机用量"
        case .succeeded: "刷新完成"
        case .failed: "刷新失败"
        }
    }
}

private struct AccountQuotaGroup: View {
    let displayName: String
    let duplicateDisplayName: String?
    let isActive: Bool
    let isScheduled: Bool
    let isCommandRunning: Bool
    let actionsExpanded: Bool
    let isConfirmingDeletion: Bool
    let onToggleActions: () -> Void
    let onToggleScheduling: () -> Void
    let onRequestDelete: () -> Void
    let onCancelDelete: () -> Void
    let onConfirmDelete: () -> Void
    let quota: MenuAccountQuota?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                            .help(displayName)

                        if isActive {
                            Text("当前")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }

                        if !isScheduled {
                            Text("已暂停")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(accountStatus)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(planName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    onToggleActions()
                } label: {
                    Image(systemName: actionsExpanded ? "xmark.circle" : "ellipsis.circle")
                        .foregroundStyle(actionsExpanded ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isCommandRunning)
                .help("账号操作")
            }

            if actionsExpanded {
                accountActions
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if quotaRows.isEmpty {
                QuotaProgressRow(
                    title: "官方额度",
                    window: nil,
                    sampledAt: nil,
                    isActive: isActive
                )
            } else {
                ForEach(quotaRows) { row in
                    QuotaProgressRow(
                        title: row.title,
                        window: row.window,
                        sampledAt: quota?.updatedAt,
                        isActive: isActive
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .animation(.easeInOut(duration: 0.16), value: actionsExpanded)
    }

    @ViewBuilder
    private var accountActions: some View {
        Group {
            if isConfirmingDeletion {
                HStack(spacing: 8) {
                    Text("确定删除这个账号？")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("取消") { onCancelDelete() }
                        .buttonStyle(.bordered)
                    Button("删除", role: .destructive) { onConfirmDelete() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 10) {
                    Button {
                        onToggleScheduling()
                    } label: {
                        Label(
                            isScheduled ? "关闭调度" : "恢复调度",
                            systemImage: isScheduled ? "pause.circle" : "play.circle")
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 4)

                    Button(role: .destructive) {
                        onRequestDelete()
                    } label: {
                        Label("删除账号", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
        }
        .disabled(isCommandRunning)
    }

    private var planName: String {
        guard let plan = quota?.planType, !plan.isEmpty else { return "" }
        return plan.replacingOccurrences(of: "chatgpt", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized
    }

    private var quotaRows: [QuotaWindowRow] {
        QuotaWindowPresentation.rows(for: quota)
    }

    private var accountStatus: String {
        AccountStatusPresentation.text(
            isScheduled: isScheduled,
            duplicateDisplayName: duplicateDisplayName,
            quota: quota
        )
    }

    private var statusColor: Color {
        isScheduled && (quota?.duplicateOf != nil || quota?.error != nil) ? .orange : .secondary
    }
}

private struct QuotaProgressRow: View {
    let title: String
    let window: MenuQuotaWindow?
    let sampledAt: Date?
    let isActive: Bool

    private var remaining: Int? {
        window.map { max(0, min(100, 100 - $0.usedPercent)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ProgressView(value: Double(remaining ?? 0), total: 100)
                .progressViewStyle(.linear)
                .tint(progressTint)
                .controlSize(.mini)
                .scaleEffect(x: 1, y: 0.48, anchor: .center)

            HStack(alignment: .firstTextBaseline) {
                Text(remaining.map { "\($0)% 剩余" } ?? "等待同步")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(resetDescription)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .regular))
            .monospacedDigit()

            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                if let paceDescription = QuotaWindowPresentation.paceDescription(
                    for: window,
                    sampledAt: sampledAt,
                    now: timeline.date
                ) {
                    Text(paceDescription)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var progressTint: Color {
        guard let remaining else { return .secondary }
        if remaining <= 1 { return .red }
        if remaining <= 20 { return .orange }
        if isActive { return Color(nsColor: .systemBlue) }
        return Color(nsColor: .secondaryLabelColor).opacity(0.82)
    }

    private var resetDescription: String {
        guard let timestamp = window?.resetsAt else { return "重置时间未知" }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let interval = resetDate.timeIntervalSinceNow
        guard interval > 0 else { return "即将重置" }

        let totalMinutes = Int(interval / 60)
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return hours > 0 ? "\(days)d \(hours)h 后重置" : "\(days)d 后重置" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m 后重置" : "\(hours)h 后重置" }
        return "\(max(1, minutes))m 后重置"
    }
}
