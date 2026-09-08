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
        .frame(minWidth: 700, minHeight: 500)
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
