import SwiftUI

/// 单个节点行：国旗 + 名称 + 协议 + 延迟 + 选中标记。
struct NodeRow: View {
    let tag: String
    let isSelected: Bool
    let groupName: String

    @State private var manager = SingBoxManager.shared
    /// 订阅解析出的完整节点信息（国旗/协议）；API 只给 tag，从这里补元数据。
    @State private var subscriptions = SubscriptionManager.shared

    /// 节点元数据：按名称从订阅缓存里找。
    private var node: ProxyNode? {
        subscriptions.allNodes.first { $0.name == tag }
    }

    /// 延迟：优先用测速结果，其次订阅缓存里的旧值。
    private var latency: LatencyResult {
        if let tested = manager.latencyByTag[tag] {
            return tested
        }
        if let node {
            if let ms = node.latency { return .value(ms) }
            return node.hasBeenTested ? .timeout : .untested
        }
        return .untested
    }

    var body: some View {
        Button {
            Task {
                try? await manager.switchNode(groupTag: groupName, nodeTag: tag)
                await manager.refreshGroups()
            }
        } label: {
            HStack(spacing: 7) {
                CountryFlagView(countryCode: node?.countryCode)

                Text(tag)
                    .font(.system(size: 12))
                    .foregroundStyle(ColorToken.textPrimary)
                    .lineLimit(1)

                ProtocolTag(proxyProtocol: node?.proxyProtocol)

                Spacer()

                LatencyBadge(result: latency)

                // 选中标记
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? ColorToken.accent : Color.clear)
            }
            .padding(.leading, 30)   // 与组头角标对齐
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                isSelected
                ? ColorToken.accent.opacity(0.10)
                : Color.clear
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NodeRow(tag: "香港 IEPL 01 · 专线", isSelected: true, groupName: "PROXY")
        .frame(width: 340)
}
