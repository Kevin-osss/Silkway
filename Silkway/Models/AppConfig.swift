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

    init() {}
}
