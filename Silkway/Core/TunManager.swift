import Foundation
import ServiceManagement

/// TUN 模式管理器。
///
/// 务实路径（不走 XPC Helper）：SMAppService.daemon 直接把包内 sing-box
/// 注册为 launchd 守护进程。launchd 以 root 拉起它 → TUN 虚拟网卡可用；
/// 配置/日志走 `/Users/Shared/Silkway/`（普通用户可写、root 可读），
/// Clash API 照旧可用 —— 策略组/测速/连接日志零改动。
///
/// 代价：plist 里写死了 `/Applications/Silkway.app`，所以 TUN 只在
/// App 放进 /Applications 后可用（手册 8.6 已注明此约束）。
@Observable
@MainActor
final class TunManager {

    static let shared = TunManager()

    /// daemon 的固定工作目录。必须用 /Users/Shared ——
    /// /Library/Application Support 需要 root，主 App 写不进去；
    /// 含用户名的路径会破坏 plist 的静态 ProgramArguments。
    static let sharedDir = URL(fileURLWithPath: "/Users/Shared/Silkway", isDirectory: true)
    static var configURL: URL { sharedDir.appendingPathComponent("tun-config.json") }

    private let daemonPlistName = "com.silkway.singbox.plist"
    private var daemon: SMAppService { .daemon(plistName: daemonPlistName) }

    private(set) var lastError: String?

    private init() {}

    // MARK: - 状态

    /// daemon 当前注册状态。
    var status: SMAppService.Status { daemon.status }

    var isRegistered: Bool { status == .enabled }

    /// TUN 是否可用（App 必须在 /Applications 下）。
    var isAvailable: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    // MARK: - 配置

    /// 生成 TUN 配置并写入共享目录，返回配置里的 API 端口。
    /// - Returns: (configURL, apiPort)。daemon 启动后主 App 通过这个端口连 Clash API。
    @discardableResult
    func writeConfig(nodes: [ProxyNode], config: AppConfig, apiPort: UInt16, mixedPort: UInt16) throws -> URL {
        var tunConfig = config
        tunConfig.tunEnabled = true   // 强制 TUN inbound

        let ruleSets = config.bypassChinaMainland ? RuleSetManager.shared.ruleSetConfig() : []
        let data = try ConfigBuilder.data(
            nodes: nodes,
            config: tunConfig,
            apiPort: apiPort,
            mixedPort: mixedPort,
            ruleSets: ruleSets
        )

        try FileManager.default.createDirectory(at: Self.sharedDir, withIntermediateDirectories: true)
        try data.write(to: Self.configURL, options: .atomic)
        return Self.configURL
    }

    // MARK: - 注册 / 注销

    /// 注册 daemon（launchd 立即拉起 sing-box 为 root 进程）。
    /// 需要用户在「系统设置 → 通用 → 登录项与扩展」中批准。
    func register() throws {
        lastError = nil
        do {
            try daemon.register()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// 注销 daemon（launchd 终止 sing-box 进程）。
    func unregister() async throws {
        try await daemon.unregister()
    }

    /// 打开系统设置的批准页面（status == .requiresApproval 时引导用户）。
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
