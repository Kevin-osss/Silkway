import Foundation

/// 把 Silkway 内部模型转换为 sing-box JSON 配置。
///
/// 输入：节点、应用配置、动态端口。
/// 输出：可以写入 `config.json` 的字典（再用 JSONSerialization 序列化）。
enum ConfigBuilder {

    /// 配置生成过程中可能遇到的错误。
    enum Error: Swift.Error {
        case noNodesAvailable
        case portAllocationFailed
        case serializationFailed(Swift.Error)
    }

    /// 生成 sing-box 配置。
    ///
    /// - Parameters:
    ///   - nodes: 可用节点。至少要有 direct-out，否则函数会自动注入一个。
    ///   - config: 应用配置
    ///   - apiPort: Clash API 端口
    ///   - mixedPort: mixed 入站端口
    ///   - profile: 完整配置（自带策略组与规则）。提供时走「完整配置模式」，
    ///     使用 profile.outbounds + profile.rules，忽略 nodes，只包装
    ///     inbounds/dns/api/route.final。
    ///   - ruleSets: 本地规则集（geoip-cn / geosite-cn）的引用定义
    static func build(
        nodes: [ProxyNode],
        config: AppConfig = AppConfig(),
        apiPort: UInt16,
        mixedPort: UInt16,
        profile: ImportedProfile? = nil,
        ruleSets: [[String: Any]] = []
    ) -> [String: Any] {
        if let profile {
            return buildProfile(
                profile, config: config, apiPort: apiPort,
                mixedPort: mixedPort, ruleSets: ruleSets
            )
        }
        return buildNodes(
            nodes, config: config, apiPort: apiPort,
            mixedPort: mixedPort, ruleSets: ruleSets
        )
    }

    // MARK: - 完整配置模式

    /// 用导入的完整配置生成最终配置。
    ///
    /// 与节点模式的核心区别：出站（含 selector/urltest 策略组）和路由规则
    /// 全部来自 profile，我们只负责包装 inbounds/dns/api 这些运行时层。
    /// 不修改 profile 的规则语义 —— 用户导入的配置分流是什么样就是什么样。
    private static func buildProfile(
        _ profile: ImportedProfile,
        config: AppConfig,
        apiPort: UInt16,
        mixedPort: UInt16,
        ruleSets: [[String: Any]]
    ) -> [String: Any] {
        // 出站：原样使用 profile 的（已含策略组 + 节点）
        var allOutbounds: [[String: Any]] = profile.outbounds.compactMap { raw in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        // 保证 direct-out 存在（Clash 规则的 DIRECT 目标依赖它）
        if !allOutbounds.contains(where: { $0["tag"] as? String == "direct-out" }) {
            allOutbounds.append(["type": "direct", "tag": "direct-out"])
        }
        // REJECT 目标需要 block 出站（Clash 的 REJECT 语义）
        if !allOutbounds.contains(where: { $0["tag"] as? String == "REJECT" }) {
            allOutbounds.append(["type": "block", "tag": "REJECT"])
        }

        // 规则：原样使用 profile 的；规则引用的 rule_set 由我们注入
        let rules: [[String: Any]] = profile.rules.compactMap { raw in
            guard let data = raw.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        // final：配置的兜底。Clash 的 MATCH 已在导入时提取，这里由调用方
        // 通过 AppConfig.mode 决定 —— 规则模式下用配置自带的 final（若有），
        // 否则用第一个策略组；全局/直连模式覆盖为用户显式选择。
        var route: [String: Any] = ["rules": rules]
        if config.mode == .global {
            route["final"] = profile.proxyGroups.first?.name ?? "direct-out"
        } else if config.mode == .direct {
            route["final"] = "direct-out"
        } else {
            // 规则模式：优先配置自带的 final，其次第一个策略组
            route["final"] = profileFinalTag(profile) ?? profile.proxyGroups.first?.name ?? "direct-out"
        }
        route["default_domain_resolver"] = "local"

        if config.tunEnabled {
            route["auto_detect_interface"] = true
        }
        if !ruleSets.isEmpty {
            route["rule_set"] = ruleSets
        }

        return [
            "log": ["level": "info", "output": "sing-box.log"],
            "dns": dnsConfig(profile: config.dnsProfile),
            "inbounds": inbounds(config: config, mixedPort: mixedPort),
            "outbounds": allOutbounds,
            "route": route,
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(apiPort)",
                    "secret": ""
                ],
                "cache_file": ["enabled": true, "path": "cache.db"]
            ]
        ]
    }

    /// 从 rawConfig 里提取 sing-box 配置自带的 route.final（若有）。
    private static func profileFinalTag(_ profile: ImportedProfile) -> String? {
        guard let raw = profile.rawConfig,
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = dict["route"] as? [String: Any]
        else { return nil }
        return route["final"] as? String
    }

    // MARK: - 节点模式（原有逻辑）

    private static func buildNodes(
        _ nodes: [ProxyNode],
        config: AppConfig,
        apiPort: UInt16,
        mixedPort: UInt16,
        ruleSets: [[String: Any]]
    ) -> [String: Any] {
        // 只保留成功还原 outbound 的节点（有完整凭证的）
        let outbounds = nodes.compactMap { outbound(from: $0) }

        // 始终保留一个 direct-out
        var allOutbounds = outbounds
        if !allOutbounds.contains(where: { $0["tag"] as? String == "direct-out" }) {
            allOutbounds.append(["type": "direct", "tag": "direct-out"])
        }

        // PROXY selector 包含所有非 direct 的出站
        let selectableTags = allOutbounds
            .compactMap { $0["tag"] as? String }
            .filter { $0 != "direct-out" }
        let defaultOutbound = selectableTags.first ?? "direct-out"

        let selector: [String: Any] = [
            "type": "selector",
            "tag": "PROXY",
            "outbounds": selectableTags.isEmpty ? ["direct-out"] : selectableTags,
            "default": defaultOutbound
        ]
        allOutbounds.insert(selector, at: 0)

        // 路由规则（顺序即优先级，先匹配先生效）
        var rules: [[String: Any]] = []

        // 1. TUN 模式：DNS 查询交给 sing-box 自己的 DNS 模块处理。
        //    不劫持的话，应用的 DNS 请求会作为普通 UDP 流量被 final 规则
        //    甩给代理，既慢又可能形成"解析机场域名要先连上机场"的死循环。
        if config.tunEnabled {
            rules.append(["action": "hijack-dns", "protocol": "dns"])
        }

        // 2. 私有地址直连。TUN 接管全部流量后，不加这条会把
        //    路由器后台、打印机、NAS、AirDrop 全都送去代理 —— 必然不通。
        rules.append(["ip_is_private": true, "outbound": "direct-out"])

        // 3. ICMP 直连。shadowsocks/trojan 等协议不支持 ICMP，
        //    走代理会报 "icmp is not supported by default outbound"，ping 全废。
        if config.tunEnabled {
            rules.append(["network": "icmp", "outbound": "direct-out"])
        }

        // 4. 自定义直连域名（用户优先级最高的业务规则）
        if !config.customDirectDomains.isEmpty {
            rules.append([
                "domain_suffix": config.customDirectDomains,
                "outbound": "direct-out"
            ])
        }

        // 5. 绕过中国大陆（geosite-cn 域名 + geoip-cn IP 双保险）
        if config.bypassChinaMainland {
            let availableTags = ruleSets.compactMap { $0["tag"] as? String }
            if availableTags.contains("geosite-cn") {
                rules.append(["rule_set": ["geosite-cn"], "outbound": "direct-out"])
            }
            if availableTags.contains("geoip-cn") {
                rules.append(["rule_set": ["geoip-cn"], "outbound": "direct-out"])
            }
        }

        var route: [String: Any] = [
            "rules": rules,
            "final": config.mode == .direct ? "direct-out" : "PROXY",
            // 出站服务器域名的解析器。不指定时 sing-box 在启动瞬间可能
            // 还没准备好 DNS，导致首次连接报 "lookup xxx: context canceled"。
            "default_domain_resolver": "local"
        ]
        // TUN 模式必须开 auto_detect_interface（在 route 层），
        // 否则代理流量会被重新路由回 TUN 形成死循环
        if config.tunEnabled {
            route["auto_detect_interface"] = true
        }
        if !ruleSets.isEmpty {
            route["rule_set"] = ruleSets
        }

        return [
            "log": [
                "level": "info",
                "output": "sing-box.log"
            ],
            "dns": dnsConfig(profile: config.dnsProfile),
            "inbounds": inbounds(config: config, mixedPort: mixedPort),
            "outbounds": allOutbounds,
            "route": route,
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(apiPort)",
                    "secret": ""
                ],
                "cache_file": [
                    "enabled": true,
                    "path": "cache.db"
                ]
            ]
        ]
    }

    /// 生成入站配置。TUN 模式用 tun 虚拟网卡接管全部流量；
    /// 系统代理模式用 mixed 端口（127.0.0.1 本地回环）。
    /// 两者由 AppConfig.tunEnabled 互斥，不会同时出现。
    static func inbounds(config: AppConfig, mixedPort: UInt16) -> [[String: Any]] {
        if config.tunEnabled {
            // 语法对应 sing-box 1.10+（address 取代了 inet4_address）。
            // auto_detect_interface 必须为 true，否则代理流量回流 TUN 死循环。
            // stack 用 gvisor：macOS 用户态实现，稳定性好于 system。
            return [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30"],
                // 不配 IPv6 地址：国内宽带普遍有原生 v6 但机场 SS 节点
                // 往往没有 v6 出口。不配 v6 地址 = v6 流量不进 TUN，
                // 避免 direct 出站拨 v6 报 "no route to host"（2026-09-08 实测）。
                // macOS 会自行降级到 IPv4。
                "mtu": 9000,
                "auto_route": true,
                "strict_route": true,
                "stack": "gvisor"
            ]]
        }
        return [[
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": Int(mixedPort)
        ]]
    }

    /// DNS 配置（sing-box 1.12+ 新格式）。
    ///
    /// 只有经过实战验证的组合才提供 —— 境外 DoT 在国内会被 RST，不提供。
    /// - system: local 直连，用系统 DNS，最兼容国内网络
    /// - ali: 阿里 DoH
    /// - tencent: 腾讯 DoH
    static func dnsConfig(profile: String) -> [String: Any] {
        let servers: [[String: Any]]
        switch profile {
        case "ali":
            servers = [
                ["tag": "dns-remote", "type": "https", "server": "223.5.5.5", "domain_resolver": "local"],
                ["tag": "local", "type": "local"]
            ]
        case "tencent":
            servers = [
                ["tag": "dns-remote", "type": "https", "server": "119.29.29.29", "domain_resolver": "local"],
                ["tag": "local", "type": "local"]
            ]
        default: // "system"
            servers = [["tag": "local", "type": "local"]]
        }
        return [
            "servers": servers,
            // 优先返回 IPv4。关键：国内宽带普遍有原生 IPv6（240e::），
            // 但机场的 shadowsocks 节点往往没有 IPv6 出口 —— macOS 的
            // Happy Eyeballs 会优先试 IPv6，结果有 AAAA 记录的站点（Google/
            // Cloudflare/大量 CDN）全部连不上，纯 IPv4 站点却正常，
            // 表现就是"有的网站能开有的不能"（2026-09-08 真实问题）。
            // 注：TUN 仍保留 IPv6 地址，让残留的 IPv6 流量被隧道捕获而不是裸奔泄漏。
            "strategy": "prefer_ipv4"
        ]
    }

    /// 把 ProxyNode 转为 sing-box outbound 字典。
    ///
    /// 优先取解析器生成的 outboundJSON（含 UUID/密码/传输层/TLS），
    /// 只覆盖 tag 字段（因为 tag 用于策略组引用，必须由我们控制）。
    /// outboundJSON 为 nil 的节点（YAML 子集等只解析出元数据的格式）返回 nil 被跳过。
    private static func outbound(from node: ProxyNode) -> [String: Any]? {
        guard let json = node.outboundJSON,
              let data = json.data(using: .utf8),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        dict["tag"] = node.displayName
        return dict
    }

    /// 生成用于写入磁盘的 JSON 数据。
    static func data(
        nodes: [ProxyNode],
        config: AppConfig = AppConfig(),
        apiPort: UInt16,
        mixedPort: UInt16,
        profile: ImportedProfile? = nil,
        ruleSets: [[String: Any]] = []
    ) throws -> Data {
        let dict = build(
            nodes: nodes, config: config, apiPort: apiPort,
            mixedPort: mixedPort, profile: profile, ruleSets: ruleSets
        )
        do {
            return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw Error.serializationFailed(error)
        }
    }
}

extension ProxyNode {
    /// 显示在 sing-box 配置里的 tag。
    /// 节点名里常有 emoji/国旗和空格，直接当 tag 没问题，但太长影响日志可读性。
    fileprivate var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(proxyProtocol.rawValue)-\(server)" : trimmed
    }
}
