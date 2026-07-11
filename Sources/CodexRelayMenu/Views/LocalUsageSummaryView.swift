import SwiftUI

struct LocalUsageSummaryView: View {
    let usage: LocalUsageSnapshot?
    let isLoading: Bool
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("本机用量")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("全部账号 · 估算")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            if let usage {
                HStack(spacing: 16) {
                    usageMetric("今日", value: currency(usage.sessionCostUSD))
                    usageMetric("近 30 天", value: currency(usage.last30DaysCostUSD))
                    usageMetric("30 天 token", value: compact(usage.last30DaysTokens))
                    usageMetric("最近 token", value: compact(usage.sessionTokens))
                }

                LocalUsageBars(days: usage.daily)
                    .frame(height: 35)

                HStack(spacing: 5) {
                    Text("最常用模型：\(usage.mostUsedModel ?? "—")")
                    Spacer()
                    Text("本机 Codex 日志 · API 等值")
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取本机 Codex 日志…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 58)
            } else {
                Label(error ?? "本机用量暂不可用", systemImage: "chart.bar.xaxis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 58)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func usageMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func currency(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func compact(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let number = Double(value)
        if number >= 1_000_000_000 {
            return String(format: "%.1fB", number / 1_000_000_000)
        }
        if number >= 1_000_000 {
            return String(format: "%.0fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.0fK", number / 1_000)
        }
        return String(value)
    }
}

private struct LocalUsageBars: View {
    let days: [LocalUsageDay]

    private var visibleDays: [LocalUsageDay] { Array(days.suffix(30)) }
    private var maximum: Double { max(visibleDays.map(\.totalCost).max() ?? 0, 0.01) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(visibleDays) { day in
                Capsule()
                    .fill(.primary.opacity(day.id == visibleDays.last?.id ? 0.85 : 0.28))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, 35 * day.totalCost / maximum))
                    .help("\(day.date) · \(day.totalCost.formatted(.currency(code: "USD").precision(.fractionLength(2))))")
            }
        }
    }
}
