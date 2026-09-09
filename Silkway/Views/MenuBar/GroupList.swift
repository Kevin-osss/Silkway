import SwiftUI

/// 首页策略组列表。
///
/// 两件事与早期版本不同：
/// 1. **壳组过滤**：完整配置常见 GLOBAL → PROXY 的嵌套，GLOBAL 只有一个
///    成员且是组，显示它只是噪音（设计评审结论：加白名单约束，防止误伤
///    用户自定义的单成员组）。节点模式只有一个 PROXY 组时不过滤——
///    过滤完一个组都不剩就把入口也弄丢了。
/// 2. **高度上限**：策略组区最多 ~240pt，超出内部滚动，底部操作区始终可见。
struct GroupList: View {
    @State private var manager = SingBoxManager.shared
    @State private var contentHeight: CGFloat = 0

    /// 点击组 → 进入二级选择页
    var onSelectGroup: (ProxyGroup) -> Void

    /// 过滤壳组后的可见组（壳组过滤规则见 Array.hidingShellGroups）
    var visibleGroups: [ProxyGroup] {
        manager.groups.hidingShellGroups
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(visibleGroups) { group in
                    GroupRow(group: group) {
                        onSelectGroup(group)
                    }
                }
            }
            .padding(.bottom, 6)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .scrollIndicators(.hidden)
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 40), Self.maxListHeight))
    }

    static let maxListHeight: CGFloat = 240

    /// 量取滚动内容真实高度，用于让弹窗自适应。
    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
}

/// 批量测速按钮 + 进度条（从 GroupList 顶部移到 footer 附近，
/// 首页垂直空间让给快捷控制区与策略组）。
struct TestSpeedButton: View {
    @State private var manager = SingBoxManager.shared

    var body: some View {
        VStack(spacing: 4) {
            Button {
                Task { await manager.testLatency() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 10, weight: .semibold))
                    Text(manager.isTestingLatency ? "测速中…" : "测速")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(ColorToken.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(manager.isTestingLatency)

            if manager.isTestingLatency {
                ProgressView(value: manager.latencyTestProgress)
                    .progressViewStyle(.linear)
                    .tint(ColorToken.accent)
            }
        }
    }
}

extension Array where Element == ProxyGroup {
    /// 过滤壳组后的可见组。
    ///
    /// 完整配置常见 GLOBAL → PROXY 的嵌套：GLOBAL 只有一个成员且是组，
    /// 显示它只是噪音。约束条件（设计评审结论）：名字在白名单内（GLOBAL/Proxy，
    /// 内核壳组的惯例命名）+ 单成员 + 成员是组 —— 三个条件同时满足才过滤，
    /// 防止误伤用户自定义的单成员组（如「轻度代理」只挂一个落地组是合法场景）。
    ///
    /// 另外：过滤完一个不剩（如节点模式只有 PROXY 且命中白名单）就不过滤，
    /// 否则把唯一的节点选择入口也弄丢了。
    var hidingShellGroups: [ProxyGroup] {
        let groupNames = Set(map(\.name))
        let shells = Set(
            filter { group in
                ["global", "proxy"].contains(group.name.lowercased()) &&
                group.memberTags.count == 1 &&
                groupNames.contains(group.memberTags[0])
            }
            .map(\.name)
        )
        let filtered = filter { !shells.contains($0.name) }
        return filtered.isEmpty ? self : filtered
    }
}

#Preview {
    GroupList(onSelectGroup: { _ in })
        .frame(height: 200)
}
