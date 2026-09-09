import SwiftUI
import AppKit

/// 底部操作区：测速 / 更新订阅 / 连接日志 / 设置 / 退出。
struct ActionFooter: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage("silkway.settings.tab") private var settingsTab = "general"

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 14) {
                TestSpeedButton()

                Spacer()

                Button {
                    Task { await SubscriptionManager.shared.updateAll() }
                } label: {
                    Label("更新订阅", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ColorToken.textSecondary)

                Button {
                    settingsTab = "connections"
                    openSettings()
                } label: {
                    Label("连接日志", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ColorToken.textSecondary)

                Button {
                    settingsTab = "general"
                    openSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ColorToken.textSecondary)

                Button {
                    // 先停 sing-box 再退出 —— 直接 NSApp.terminate 会留孤儿进程
                    // 继续占端口和 cache.db 锁，下次启动必冲突
                    Task {
                        await SingBoxManager.shared.stop()
                        NSApp.terminate(nil)
                    }
                } label: {
                    Label("退出", systemImage: "power")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ColorToken.textSecondary)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    ActionFooter()
        .padding()
}
