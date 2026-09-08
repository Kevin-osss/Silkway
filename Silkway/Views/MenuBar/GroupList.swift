import SwiftUI

/// 策略组可折叠列表。每行展开显示组内节点，顶部有批量测速入口。
struct GroupList: View {
    @State private var manager = SingBoxManager.shared
    @State private var openGroup: String?
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            // 用 VStack 而非 LazyVStack：懒加载时 GeometryReader 量不到未渲染
            // 部分的高度，弹窗会算短。组数量有限，全量渲染可接受。
            VStack(spacing: 0) {
                // 批量测速按钮（设计稿：顶部进度条推进）
                TestSpeedButton()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                ForEach(manager.groups) { group in
                    GroupRow(group: group, isOpen: openGroup == group.name) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            openGroup = openGroup == group.name ? nil : group.name
                        }
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
        // 随内容长高，到屏幕上限才滚动 —— 而不是永远固定 300pt
        .frame(height: min(max(contentHeight, 60), Self.maxListHeight))
    }

    /// 列表区最大高度。
    ///
    /// 菜单栏弹窗可以占到屏幕可见区高度，但要给头部（电源+速率）、
    /// 模式选择、底部操作区和分割线留位（实测约 200pt）。
    static var maxListHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, screenHeight - 200)
    }
}

/// 量取滚动内容真实高度，用于让弹窗自适应。
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 批量测速按钮 + 进度条。
struct TestSpeedButton: View {
    @State private var manager = SingBoxManager.shared

    var body: some View {
        VStack(spacing: 6) {
            Button {
                Task { await manager.testLatency() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 11, weight: .semibold))
                    Text(manager.isTestingLatency ? "测速中…" : "批量测速")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(ColorToken.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(ColorToken.accent)
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

#Preview {
    GroupList()
        .frame(height: 300)
}
