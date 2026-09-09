import SwiftUI

/// 策略组二级选择页：点首页的组进入，在这里选节点/子组。
///
/// 不在首页展开节点列表的原因：展开后 100+ 节点把弹窗撑到整屏，
/// 底部操作被挤出视口。二级页有自己的滚动区，弹窗高度稳定。
struct GroupDetailView: View {
    let group: ProxyGroup
    @Binding var path: [ProxyGroup]

    @State private var manager = SingBoxManager.shared
    @State private var subscriptions = SubscriptionManager.shared
    @State private var searchText = ""

    /// 成员里的子组（策略组可以嵌套引用其他组）
    private var subGroups: [ProxyGroup] {
        let tags = Set(group.memberTags)
        return manager.groups.filter { tags.contains($0.name) }
    }

    private var nodeMembers: [String] {
        let groupNames = Set(manager.groups.map(\.name))
        return group.memberTags.filter { !groupNames.contains($0) }
    }

    private var filteredNodes: [String] {
        guard !searchText.isEmpty else { return nodeMembers }
        return nodeMembers.filter { tag in
            tag.localizedCaseInsensitiveContains(searchText) ||
            (subscriptions.allNodes.first { $0.name == tag }?.server
                .localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 返回 + 组名
            HStack(spacing: 6) {
                Button {
                    path.removeLast()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text("返回")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(ColorToken.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                // 与左侧返回按钮占位对称，保持组名居中
                Text("返回")
                    .font(.system(size: 12))
                    .hidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 14)

            // 节点多时才显示搜索框（设计评审：≤15 个节点打字搜索不如直接点）
            if nodeMembers.count > 15 {
                SearchField(text: $searchText, prompt: "搜索节点名或服务器")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                Divider().padding(.horizontal, 14)
            }

            ScrollView {
                VStack(spacing: 0) {
                    // 子组：进入更深层
                    ForEach(subGroups) { sub in
                        SubgroupRow(group: sub) {
                            path.append(sub)
                        }
                    }

                    // 节点成员
                    ForEach(filteredNodes, id: \.self) { tag in
                        MemberNodeRow(
                            tag: tag,
                            group: group,
                            isSelected: group.selectedTag == tag
                        )
                    }

                    if filteredNodes.isEmpty, !searchText.isEmpty {
                        Text("无匹配节点")
                            .font(.system(size: 11))
                            .foregroundStyle(ColorToken.disabled)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: 300)
    }
}

/// 子组行：标识这是组而非节点，点击进入该组的详情。
private struct SubgroupRow: View {
    let group: ProxyGroup
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(ColorToken.textSecondary)
                    .frame(width: 18)

                Text(group.name)
                    .font(.system(size: 12))
                    .foregroundStyle(ColorToken.textPrimary)
                    .lineLimit(1)

                Text(group.type.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(ColorToken.disabled)

                Spacer()

                if let now = group.selectedTag {
                    Text(now)
                        .font(.system(size: 11))
                        .foregroundStyle(ColorToken.textSecondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ColorToken.disabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 节点成员行。urltest/loadbalance 组的成员由内核自动决策，不可点选——
/// 把它们显示成可选会让用户误以为点击生效了。
private struct MemberNodeRow: View {
    let tag: String
    let group: ProxyGroup
    let isSelected: Bool

    @State private var manager = SingBoxManager.shared
    @State private var subscriptions = SubscriptionManager.shared

    private var node: ProxyNode? {
        subscriptions.allNodes.first { $0.name == tag }
    }

    private var latency: LatencyResult {
        if let tested = manager.latencyByTag[tag] { return tested }
        if let node {
            if let ms = node.latency { return .value(ms) }
            return node.hasBeenTested ? .timeout : .untested
        }
        return .untested
    }

    var body: some View {
        Button {
            guard group.isUserSelectable else { return }
            Task {
                try? await manager.switchNode(groupTag: group.name, nodeTag: tag)
                await manager.refreshGroups()
                // 选完即返回首页，减少一次手动返回
                // 用延迟让选中态闪一下再退出，反馈更明确
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        } label: {
            HStack(spacing: 7) {
                CountryFlagView(countryCode: node?.countryCode)

                Text(displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(ColorToken.textPrimary)
                    .lineLimit(1)

                ProtocolTag(proxyProtocol: node?.proxyProtocol)

                Spacer()

                LatencyBadge(result: latency)

                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? ColorToken.accent : Color.clear)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? ColorToken.accent.opacity(0.10) : Color.clear)
            .opacity(group.isUserSelectable ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .disabled(!group.isUserSelectable)
    }

    /// 节点名带国旗 emoji 时（机场命名习惯「🇭🇰 香港 01」），
    /// 左侧 CountryFlagView 已渲染旗帜，名字里的 emoji 就是重复且
    /// 在不同字体下会显示成方框（见菜单截图问题）。剥掉名字开头的区域指示符对。
    private var displayName: String {
        var scalars = Array(tag.unicodeScalars)
        // 区域指示符（U+1F1E6–U+1F1FF）成对出现，旗帜 = 两个
        while scalars.count >= 2,
              scalars[0].value >= 0x1F1E6, scalars[0].value <= 0x1F1FF,
              scalars[1].value >= 0x1F1E6, scalars[1].value <= 0x1F1FF {
            scalars.removeFirst(2)
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespaces)
    }
}
