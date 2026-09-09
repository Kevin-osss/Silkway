import SwiftUI

/// 策略组行：角标 + 组名 + 当前选择 + 箭头。点击进入二级选择页。
///
/// 早期版本在这里内联展开节点列表，展开后 100+ 节点把弹窗撑满屏幕。
/// 现在只作为导航入口（GroupDetailView 负责节点选择）。
struct GroupRow: View {
    let group: ProxyGroup
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
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

                // 自动决策的组标注类型，避免用户以为可以手动选
                if !group.isUserSelectable {
                    Text(group.type.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(ColorToken.disabled)
                }

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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            memberTags: ["香港 IEPL 01", "日本 东京 BGP"],
            selectedTag: "香港 IEPL 01"
        ),
        onSelect: {}
    )
}
