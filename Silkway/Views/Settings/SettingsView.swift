import SwiftUI

/// 设置面板（手册 5.2：TabView Sidebar 样式，minWidth 700）。
///
/// 当前是 P0 空壳 —— 各 Tab 只有占位内容，P1 起逐项实现。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            SubscriptionView()
                .tabItem { Label("订阅", systemImage: "square.stack.3d.up") }
            ProxyView()
                .tabItem { Label("代理节点", systemImage: "globe.asia.australia") }
            RuleView()
                .tabItem { Label("路由规则", systemImage: "list.bullet.indent") }
            DNSView()
                .tabItem { Label("DNS", systemImage: "point.3.filled.connected.trianglepath.dotted") }
            ConnectionView()
                .tabItem { Label("连接日志", systemImage: "arrow.left.arrow.right") }
            AboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        // 只给 min 不给 ideal 会让窗口被内容的理想尺寸牵着走：
        // 切 Tab、流量条出现/消失、长 URL 文本……都会顶动窗口尺寸，
        // 而工具栏图标是居中布局，窗口一变宽整排图标就平移 = 肉眼可见的抖动。
        // （2026-09-08 实测：同一页面两次截图窗口为 742×552 和 736×624）
        // 明确给出 ideal 后，窗口只认这个尺寸；maxWidth/Height 留 .infinity
        // 是为了内容仍能填满、用户仍能手动缩放。
        .frame(
            minWidth: 700, idealWidth: 720, maxWidth: .infinity,
            minHeight: 500, idealHeight: 560, maxHeight: .infinity
        )
    }
}

struct AboutView: View {
    /// 应用图标直接从 Dock 图标取（NSApplication.applicationIconImage 自动用 AppIcon），
    /// 不用手动指定图片资源 —— 换图标时零改动。
    private var appIcon: NSImage { NSApp.applicationIconImage ?? NSImage() }

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(radius: 4, y: 2)

            Text("Silkway")
                .font(.title.bold())

            Text("版本 \(versionString)")
                .foregroundStyle(ColorToken.textSecondary)

            Text("基于 sing-box 1.13 的 macOS 代理客户端")
                .font(.callout)
                .foregroundStyle(ColorToken.textSecondary)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SettingsView()
}
