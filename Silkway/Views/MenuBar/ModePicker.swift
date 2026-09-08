import SwiftUI

/// 模式切换：全局 / 规则 / 直连（设计稿为胶囊分段控件）。
struct ModePicker: View {
    @State private var manager = SingBoxManager.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProxyMode.allCases) { mode in
                Button {
                    Task { await manager.setMode(mode) }
                } label: {
                    Text(mode.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            manager.mode == mode
                            ? Color.white.opacity(0.18)
                            : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(
                            manager.mode == mode
                            ? ColorToken.textPrimary
                            : ColorToken.textSecondary.opacity(0.75)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ModePicker()
        .padding()
        .frame(width: 300)
}
