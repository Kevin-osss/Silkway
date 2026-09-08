import SwiftUI

/// 状态头部：电源开关 + 当前状态 + 实时速率（设计稿 1a 顶部区域）。
struct StatusHeader: View {
    @State private var manager = SingBoxManager.shared

    var body: some View {
        HStack(spacing: 12) {
            PowerButton()
            statusColumn
            Spacer()
            speedColumn
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // 状态文字：已连接 + 模式 · 运行时长
    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(manager.isRunning ? "已连接" : "未连接")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(manager.isRunning ? ColorToken.success : ColorToken.textPrimary)

            if manager.isRunning {
                Text("\(manager.mode.displayName) · \(uptimeText)")
                    .font(.system(size: 11))
                    .foregroundStyle(ColorToken.textSecondary)
            } else {
                Text("点按连接")
                    .font(.system(size: 11))
                    .foregroundStyle(ColorToken.textSecondary)
            }
        }
    }

    // 实时上下行速率
    private var speedColumn: some View {
        VStack(alignment: .trailing, spacing: 3) {
            speedRow(icon: "arrow.up", value: manager.lastTraffic?.up ?? 0)
            speedRow(icon: "arrow.down", value: manager.lastTraffic?.down ?? 0)
        }
    }

    private func speedRow(icon: String, value: Int64) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
            Text(Formatters.speed(value))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(ColorToken.textSecondary)
    }

    private var uptimeText: String {
        guard let start = manager.startTime else { return "00:00:00" }
        return Formatters.duration(Date().timeIntervalSince(start))
    }
}

/// 电源开关。设计稿：连接中绿色 + 脉冲光环动画，断开灰色静默。
struct PowerButton: View {
    @State private var manager = SingBoxManager.shared
    @State private var pulsing = false

    var body: some View {
        Button {
            Task { await manager.toggle() }
        } label: {
            ZStack {
                // 脉冲光环（仅连接时）
                if manager.isRunning {
                    Circle()
                        .stroke(ColorToken.success.opacity(0.55), lineWidth: 1.5)
                        .scaleEffect(pulsing ? 1.6 : 1.0)
                        .opacity(pulsing ? 0 : 0.55)
                        .animation(
                            .easeOut(duration: 2.2).repeatForever(autoreverses: false),
                            value: pulsing
                        )
                }

                Circle()
                    .fill(manager.isRunning
                          ? ColorToken.success.opacity(0.16)
                          : Color.white.opacity(0.07))
                    .frame(width: 44, height: 44)

                Image(systemName: "power")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(manager.isRunning
                                     ? ColorToken.success
                                     : ColorToken.textSecondary)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onAppear { pulsing = true }
    }
}

#Preview {
    StatusHeader()
        .padding()
}
