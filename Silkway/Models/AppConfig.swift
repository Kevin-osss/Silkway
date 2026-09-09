import Foundation

/// 应用设置。对应设计稿「设置 → 通用」页的各项开关。
struct AppConfig: Codable, Hashable, Sendable {

    // MARK: 启动行为
    var launchAtLogin: Bool = false
    var autoConnectOnLaunch: Bool = true
    var silentLaunch: Bool = false

    // MARK: 代理行为
    var mode: ProxyMode = .rule

    /// 是否接管系统代理（HTTP/HTTPS/SOCKS）。
    var systemProxyEnabled: Bool = true

    /// 是否启用 TUN 模式。
    ///
    /// 与 systemProxyEnabled **互斥** —— 两者同时开启会造成双重代理。
    /// 该约束由 SingBoxManager 强制，不在此处用 didSet 处理，
    /// 因为 Model 应保持纯数据，不承载业务规则。
    var tunEnabled: Bool = false

    // MARK: 界面
    var showSpeedInMenuBar: Bool = true

    // MARK: 测速
    /// 测速目标。用 204 端点而非首页，响应体为空，测得的才是链路延迟而非传输时间。
    var latencyTestURL: URL = URL(string: "http://cp.cloudflare.com/generate_204")!
    var latencyTestTimeout: TimeInterval = 5
    /// 并发测速上限。手册 6.4 要求限流，否则大订阅会打爆网络栈。
    var latencyTestConcurrency: Int = 10

    // MARK: 端口
    /// 混合入站端口。nil 表示每次启动动态分配（推荐）。
    ///
    /// 固定端口会与用户已装的其他 Clash 客户端冲突 —— 技术验证中
    /// 9090 实测就被占用。仅当用户有外部工具需要固定端口时才手动指定。
    var fixedMixedPort: Int?
    var fixedClashAPIPort: Int?

    // MARK: 路由规则
    /// 绕过中国大陆：geoip-cn + geosite-cn 走直连。
    /// 规则集文件由 RuleSetManager 下载到本地缓存，配置引用本地路径
    /// （不用 remote 规则集：raw.githubusercontent.com 在国内被墙，
    /// 首次下载就会卡死启动 —— 技术验证中的真实教训）。
    ///
    /// 默认开启：国内用户的首要需求就是分流。TUN 模式下不开这个，
    /// 国内流量会全部绕境外节点（2026-09-08 实测：电信/国内 IPv6 站点全挂）。
    /// 文件未下载时规则自动不注入（优雅降级），不会导致启动失败。
    var bypassChinaMainland: Bool = true

    /// 自定义域名后缀规则。匹配的域名直连（如公司内网域名）。
    /// 格式："example.com" 或 ".internal.corp"。
    var customDirectDomains: [String] = []

    // MARK: DNS
    /// DNS 方案。默认 "system"（local 直连，最兼容国内网络）。
    /// 可选 "ali"（223.5.5.5 DoH）、"tencent"（119.29.29.29 DoH）。
    /// ⚠️ 不提供境外 DoT（tls://8.8.8.8）：国内网络会被 TLS 握手 RST，
    /// 导致启动死锁 —— 技术验证实测确认。
    var dnsProfile: String = "system"

    // MARK: 订阅
    /// 拉取订阅时发送的 User-Agent。
    ///
    /// 机场普遍根据 UA 返回不同格式：含 clash → Clash YAML，
    /// 含 sing-box → sing-box 完整配置，未知 UA → base64 分享链接（或直接拒绝）。
    /// 默认报 sing-box：拿到的配置凭证最完整，无需二次转换。
    /// 开放修改是因为总有机场只认特定 UA（常见：clash-verge / v2rayN）。
    var subscriptionUserAgent: String = "sing-box/1.13.19"

    // MARK: 完整配置
    /// 当前生效的完整配置。nil 表示节点模式（ConfigBuilder 生成统一 PROXY）。
    /// 用户可在菜单栏「当前配置」处切换；切换需要重启 sing-box。
    var activeProfileID: UUID?

    init() {}
}

// MARK: - 容错解码

extension AppConfig {

    /// 手写 init(from:)，每个字段都走 decodeIfPresent + 默认值。
    ///
    /// 为什么不用合成的：Swift 合成的 Decodable 遇到缺失的 key 直接抛
    /// keyNotFound，**属性默认值救不了**。而 AppConfigStore 用 `try?` 加载，
    /// 解码失败会静默回退到全默认配置 —— 合起来的后果是：
    /// **每次给 AppConfig 新增一个字段，所有老用户的设置全部静默重置**
    /// （代理模式、开机自启、绕过大陆……全没）。
    /// 2026-09-08 加 subscriptionUserAgent 时发现并实测确认。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = AppConfig()

        d.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        d.autoConnectOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoConnectOnLaunch) ?? d.autoConnectOnLaunch
        d.silentLaunch = try c.decodeIfPresent(Bool.self, forKey: .silentLaunch) ?? d.silentLaunch
        d.mode = try c.decodeIfPresent(ProxyMode.self, forKey: .mode) ?? d.mode
        d.systemProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemProxyEnabled) ?? d.systemProxyEnabled
        d.tunEnabled = try c.decodeIfPresent(Bool.self, forKey: .tunEnabled) ?? d.tunEnabled
        d.showSpeedInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showSpeedInMenuBar) ?? d.showSpeedInMenuBar
        d.latencyTestURL = try c.decodeIfPresent(URL.self, forKey: .latencyTestURL) ?? d.latencyTestURL
        d.latencyTestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .latencyTestTimeout) ?? d.latencyTestTimeout
        d.latencyTestConcurrency = try c.decodeIfPresent(Int.self, forKey: .latencyTestConcurrency) ?? d.latencyTestConcurrency
        d.fixedMixedPort = try c.decodeIfPresent(Int.self, forKey: .fixedMixedPort)
        d.fixedClashAPIPort = try c.decodeIfPresent(Int.self, forKey: .fixedClashAPIPort)
        d.bypassChinaMainland = try c.decodeIfPresent(Bool.self, forKey: .bypassChinaMainland) ?? d.bypassChinaMainland
        d.customDirectDomains = try c.decodeIfPresent([String].self, forKey: .customDirectDomains) ?? d.customDirectDomains
        d.dnsProfile = try c.decodeIfPresent(String.self, forKey: .dnsProfile) ?? d.dnsProfile
        d.subscriptionUserAgent = try c.decodeIfPresent(String.self, forKey: .subscriptionUserAgent) ?? d.subscriptionUserAgent
        d.activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)

        self = d
    }
}
