import SwiftUI

/// 菜单栏弹窗根容器（手册 5.1：固定宽 340px，高度自适应最大 ~500px）。
struct MenuBarView: View {
    @State private var manager = SingBoxManager.shared
    @State private var subscriptions = SubscriptionManager.shared

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()

            Divider()
                .padding(.horizontal, 14)

            ModePicker()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()
                .padding(.horizontal, 14)

            if manager.isRunning, !manager.groups.isEmpty {
                // 不限高：GroupList 自己根据内容和屏幕高度决定，
                // 写死 300pt 会让弹窗永远矮一截、只能内部滚动
                GroupList()
            } else {
                emptyState
                    .frame(minHeight: 110)
            }

            Divider()
                .padding(.horizontal, 14)

            ActionFooter()
        }
        .frame(width: 340)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if let error = manager.lastError, !manager.isRunning {
                // 连接失败时错误必须可见 —— 之前 lastError 只在状态里，
                // UI 不展示，用户点连接"没反应"（2026-09-03 真实 bug）
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ColorToken.warning)
                    Text("连接失败")
                        .font(.system(size: 13))
                        .foregroundStyle(ColorToken.error)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(ColorToken.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            } else if !manager.isRunning {
                Text("未连接")
                    .font(.system(size: 13))
                    .foregroundStyle(ColorToken.textSecondary)
                Text("点击上方电源键连接")
                    .font(.system(size: 11))
                    .foregroundStyle(ColorToken.disabled)
            } else if subscriptions.subscriptions.isEmpty {
                Text("没有订阅")
                    .font(.system(size: 13))
                    .foregroundStyle(ColorToken.textSecondary)
                Text("在设置中添加订阅")
                    .font(.system(size: 11))
                    .foregroundStyle(ColorToken.disabled)
            }
            Spacer()
        }
    }
}

#Preview {
    MenuBarView()
        .frame(height: 480)
}
