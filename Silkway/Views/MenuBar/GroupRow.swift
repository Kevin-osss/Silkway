import SwiftUI

/// 单个策略组行：两字母角标 + 组名 + 当前值 + 展开箭头。
struct GroupRow: View {
    let group: ProxyGroup
    let isOpen: Bool
    let onToggle: () -> Void

    @State private var manager = SingBoxManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // 组头（可点）
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    // 两字母角标
                    Text(group.tag)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 16)
                        .background(groupAccent.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(groupAccent)

                    Text(group.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ColorToken.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // 当前选中值
                    if let selected = group.selectedTag {
                        Text(selected)
                            .font(.system(size: 11))
                            .foregroundStyle(ColorToken.textSecondary)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ColorToken.disabled)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isOpen)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 展开的节点列表
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(group.memberTags, id: \.self) { tag in
                        NodeRow(
                            tag: tag,
                            isSelected: group.selectedTag == tag,
                            groupName: group.name
                        )
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// 角标颜色：按组名哈希取色，同组稳定。
    private var groupAccent: Color {
        let palette: [Color] = [
            ColorToken.accent,
            ColorToken.success,
            ColorToken.warning,
            Color(.systemPurple),
            Color(.systemTeal),
            Color(.systemOrange),
        ]
        let hash = abs(group.name.hashValue)
        return palette[hash % palette.count]
    }
}

#Preview {
    GroupRow(
        group: ProxyGroup(
            name: "PROXY",
            type: .selector,
            tag: "PR",
            memberTags: ["香港 IEPL 01", "日本 东京 BGP", "美国 洛杉矶"],
            selectedTag: "香港 IEPL 01"
        ),
        isOpen: true,
        onToggle: {}
    )
}
