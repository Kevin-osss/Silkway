import SwiftUI
import AppKit

/// 底部操作区：打开设置 / 退出。
struct ActionFooter: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 14) {
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ColorToken.textSecondary)

            Spacer()

            Button {
                // 先停 sing-box 再退出 —— 直接 NSApp.terminate 会留孤儿进程
                // 继续占端口和 cache.db 锁，下次启动必冲突
                Task {
                    await SingBoxManager.shared.stop()
                    NSApp.terminate(nil)
                }
            } label: {
                Label("退出", systemImage: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ColorToken.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

#Preview {
    ActionFooter()
        .padding()
}
