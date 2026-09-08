import SwiftUI
import AppKit

/// 应用委托：处理系统级退出事件（Cmd+Q、Dock 右键退出、关机）。
/// 退出前必须停掉 sing-box，否则子进程变孤儿占着端口和 cache.db。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 异步停 sing-box 后再真正退出
        if SingBoxManager.shared.isRunning {
            Task {
                await SingBoxManager.shared.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

@main
struct SilkwayApp: App {
    @State private var manager = SingBoxManager.shared
    // 挂载 App 委托，接管退出事件
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // 启动后台订阅自动更新
        AutoUpdateService.shared.start()
        // 首次启动时若开启了绕过大陆但规则集未下载，后台下载（不阻塞 UI）
        Task { await AutoUpdateService.shared.ensureRuleSetsIfNeeded() }
    }

    var body: some Scene {
        // 菜单栏图标：自定义 template image（纯黑+alpha PDF，随系统深浅自动反色）。
        // 连接 = 环球轨道箭头，断开 = 同图加斜杠。
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(nsImage: menubarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    /// 根据连接状态加载连/断两态 PDF，强制 template 渲染。
    ///
    /// 不用 Asset Catalog 存这两张图：菜单栏 template image 要求纯黑+alpha，
    /// PDF 直接进 bundle 资源即可，NSImage 加载后设 isTemplate 一劳永逸。
    /// 资源缺失时回退 SF Symbol，保证菜单栏永远有图标可显示。
    private var menubarIcon: NSImage {
        let name = manager.isRunning
            ? "Silkway-menubar-connected"
            : "Silkway-menubar-disconnected"
        if let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }
        // 回退：SF Symbol（template 渲染由 SwiftUI 处理）
        return NSImage(systemSymbolName: "globe.asia.australia", accessibilityDescription: "Silkway")!
    }
}
