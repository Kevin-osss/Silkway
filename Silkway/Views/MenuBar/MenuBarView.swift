import SwiftUI

/// 菜单栏弹窗根容器（手册 5.1：固定宽 340px，高度自适应）。
///
/// 结构（设计评审后定稿）：
///   状态头（电源/速率/模式）→ 快捷控制（接管/出站/当前配置）→
///   策略组列表（壳组过滤 + 高度上限）→ 底部操作。
/// 点组进入二级选择页（GroupDetailView），节点选择不挤占首页。
struct MenuBarView: View {
    @State private var manager = SingBoxManager.shared
    @State private var subscriptions = SubscriptionManager.shared

    /// 二级页导航栈：空 = 首页；非空 = 组选择页（可嵌套子组）
    @State private var navPath: [ProxyGroup] = []

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()

            Divider()
                .padding(.horizontal, 14)

            QuickControls()

            Divider()
                .padding(.horizontal, 14)

            if let group = navPath.last {
                GroupDetailView(group: group, path: $navPath)
            } else if manager.isRunning {
                let groups = GroupList(onSelectGroup: { _ in }).visibleGroups
                if !groups.isEmpty {
                    GroupList { group in
                        navPath.append(group)
                    }
                } else {
                    emptyState
                        .frame(minHeight: 80)
                }
            } else {
                emptyState
                    .frame(minHeight: 80)
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
