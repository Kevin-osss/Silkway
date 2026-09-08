import Foundation
import Testing
@testable import SilkwayCore

/// 用 spike 目录里的 sing-box 二进制校验生成的配置是否合法。
///
/// 这是比 JSON 结构检查强得多的验证：sing-box check 会按 1.13 的 schema
/// 校验每个 outbound 的字段（类型、必填项、枚举值），凭证字段填错直接报错。
@Suite("sing-box check 校验")
struct SingBoxCheckTests {

    private static let binaryPath: String = {
        // 测试工作目录是 Package.swift 所在目录
        "\(FileManager.default.currentDirectoryPath)/spike/sing-box"
    }()

    /// 解析各协议样例 URI → 生成完整配置 → sing-box check。
    @Test("五种协议的完整配置通过 sing-box check")
    func configPassesCheck() throws {
        let vmessJSON: [String: Any] = [
            "v": 2, "ps": "香港 01", "add": "hk.example.com", "port": 443,
            "id": "11111111-2222-3333-4444-555555555555", "aid": 0,
            "net": "ws", "type": "none", "host": "hk.example.com",
            "path": "/ws", "tls": "tls", "sni": "hk.example.com",
        ]
        let vmessB64 = (try? JSONSerialization.data(withJSONObject: vmessJSON))
            .flatMap { Data($0).base64EncodedString() } ?? ""
        let uris = [
            "vmess://\(vmessB64)",
            "vless://22222222-3333-4444-5555-666666666666@jp.example.com:443?security=reality&sni=www.microsoft.com&fp=chrome&pbk=PXScH5cpX7GItYuQdbGqwCzMB3cynRBrtKIE089M_jU&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision&type=tcp#日本%20Reality",
            "trojan://secret-password@sg.example.com:443?security=tls&sni=sg.example.com&type=ws&path=%2Fws&host=sg.example.com#新加坡%20WS",
            "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@us.example.com:8388#美国",
            "hysteria2://hy2password@de.example.com:443?sni=de.example.com&insecure=0#德国",
        ]
        let nodes = uris.flatMap { SubscriptionParser.parse($0) }

        // 每个 URI 都应解析出带完整凭证的节点
        #expect(nodes.count == 5, "应解析出 5 个节点，实际 \(nodes.count)")
        for node in nodes {
            #expect(node.outboundJSON != nil, "\(node.proxyProtocol.rawValue) 缺少 outboundJSON")
        }

        // 生成配置并写入临时文件
        let config = try ConfigBuilder.data(
            nodes: nodes, apiPort: 19090, mixedPort: 17890
        )
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let configURL = tmpDir.appendingPathComponent("config.json")
        try config.write(to: configURL)

        // sing-box check 的 working directory 决定相对路径（cache.db/log）落点
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binaryPath)
        process.arguments = ["check", "-c", configURL.path, "-D", tmpDir.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        if process.terminationReason != .exit || process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            Issue.record("sing-box check 失败 (exit=\(process.terminationStatus)):\n\(errText)")
        }

        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test("YAML 子集节点（无凭证）被跳过但不影响整体配置")
    func yamlNodesSkipped() throws {
        let yaml = """
        proxies:
          - name: "节点A"
            type: trojan
            server: a.example.com
            port: 443
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 1)
        #expect(nodes.first?.outboundJSON == nil, "YAML 子集只有元数据")

        // 生成配置应只含 direct-out + selector，不 crash
        let dict = ConfigBuilder.build(nodes: nodes, apiPort: 19091, mixedPort: 17891)
        let outbounds = dict["outbounds"] as? [[String: Any]] ?? []
        #expect(outbounds.contains { $0["tag"] as? String == "direct-out" })
        #expect(outbounds.contains { $0["tag"] as? String == "PROXY" })
    }

    @Test("TUN 模式配置通过 sing-box check")
    func tunConfigPassesCheck() throws {
        var config = AppConfig()
        config.tunEnabled = true
        let data = try ConfigBuilder.data(nodes: [], config: config, apiPort: 19092, mixedPort: 17892)

        // 结构断言
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let inbounds = dict?["inbounds"] as? [[String: Any]]
        #expect(inbounds?.first?["type"] as? String == "tun")
        #expect(inbounds?.first?["auto_route"] as? Bool == true)
        // TUN 不接管 IPv6：SS 机场无 v6 出口，接管反而导致 direct 出站报 no route to host
        let addresses = inbounds?.first?["address"] as? [String] ?? []
        #expect(addresses.count == 1)
        #expect(addresses.first?.contains(".") == true, "应只含 IPv4 地址")
        #expect(addresses.first?.contains(":") == false, "不应含 IPv6 地址")
        // auto_detect_interface 必须在 route 层（1.13 挪位，inbound 层报 unknown field）
        let route = dict?["route"] as? [String: Any]
        #expect(route?["auto_detect_interface"] as? Bool == true)
        #expect(inbounds?.first?["auto_detect_interface"] == nil, "auto_detect_interface 不能在 inbound 层")

        // sing-box check 真实 schema 校验
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-tun-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let configURL = tmpDir.appendingPathComponent("config.json")
        try data.write(to: configURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binaryPath)
        process.arguments = ["check", "-c", configURL.path, "-D", tmpDir.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        if process.terminationReason != .exit || process.terminationStatus != 0 {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Issue.record("TUN 配置 check 失败: \(errText)")
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test("绕过大陆规则集注入到 route.rule_set")
    func bypassCNRules() {
        var config = AppConfig()
        config.bypassChinaMainland = true
        let ruleSets: [[String: Any]] = [
            ["tag": "geoip-cn", "type": "local", "format": "binary", "path": "/tmp/geoip-cn.srs"],
            ["tag": "geosite-cn", "type": "local", "format": "binary", "path": "/tmp/geosite-cn.srs"]
        ]
        let dict = ConfigBuilder.build(nodes: [], config: config, apiPort: 19093, mixedPort: 17893, ruleSets: ruleSets)
        let route = dict["route"] as? [String: Any]
        let rules = route?["rules"] as? [[String: Any]] ?? []
        #expect(rules.contains { ($0["rule_set"] as? [String])?.contains("geosite-cn") == true })
        #expect(rules.contains { ($0["rule_set"] as? [String])?.contains("geoip-cn") == true })
        let rs = route?["rule_set"] as? [[String: Any]] ?? []
        #expect(rs.count == 2)
    }

    @Test("自定义直连域名生成 domain_suffix 规则")
    func customDirectDomains() {
        var config = AppConfig()
        config.customDirectDomains = [".corp.example.com", "internal.local"]
        let dict = ConfigBuilder.build(nodes: [], config: config, apiPort: 19094, mixedPort: 17894)
        let route = dict["route"] as? [String: Any]
        let rules = route?["rules"] as? [[String: Any]] ?? []
        let domainRule = rules.first { $0["domain_suffix"] != nil }
        #expect(domainRule != nil)
        #expect((domainRule?["domain_suffix"] as? [String])?.count == 2)
        #expect(domainRule?["outbound"] as? String == "direct-out")
    }

    @Test("私有地址始终直连（两种模式）")
    func privateIPAlwaysDirect() {
        for tun in [false, true] {
            var config = AppConfig()
            config.tunEnabled = tun
            let dict = ConfigBuilder.build(nodes: [], config: config, apiPort: 19095, mixedPort: 17895)
            let rules = (dict["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
            let privateRule = rules.first { $0["ip_is_private"] as? Bool == true }
            #expect(privateRule?["outbound"] as? String == "direct-out",
                    "tunEnabled=\(tun) 时局域网必须直连，否则路由器/打印机全不通")
        }
    }

    @Test("TUN 模式专属规则：DNS 劫持 + ICMP 直连")
    func tunOnlyRules() {
        var tunConfig = AppConfig()
        tunConfig.tunEnabled = true
        let tunRules = (ConfigBuilder.build(nodes: [], config: tunConfig, apiPort: 19096, mixedPort: 17896)["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
        #expect(tunRules.contains { $0["action"] as? String == "hijack-dns" }, "TUN 必须劫持 DNS")
        #expect(tunRules.contains { $0["network"] as? String == "icmp" }, "TUN 必须把 ICMP 走直连，否则 ping 全废")

        // 系统代理模式不应有这两条
        let proxyRules = (ConfigBuilder.build(nodes: [], config: AppConfig(), apiPort: 19097, mixedPort: 17897)["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
        #expect(!proxyRules.contains { $0["action"] as? String == "hijack-dns" })
        #expect(!proxyRules.contains { $0["network"] as? String == "icmp" })
    }

    @Test("default_domain_resolver 防首连解析竞态")
    func domainResolverSet() {
        let dict = ConfigBuilder.build(nodes: [], config: AppConfig(), apiPort: 19098, mixedPort: 17898)
        let route = dict["route"] as? [String: Any]
        #expect(route?["default_domain_resolver"] as? String == "local")
        // 必须真的存在一个 tag 为 local 的 DNS server，否则 sing-box 启动报错
        let servers = (dict["dns"] as? [String: Any])?["servers"] as? [[String: Any]] ?? []
        #expect(servers.contains { $0["tag"] as? String == "local" })
    }

    @Test("DNS 优先返回 IPv4（防原生 IPv6 + 无 IPv6 出口机场的卡死）")
    func dnsPrefersIPv4() {
        for profile in ["system", "ali", "tencent"] {
            let dns = ConfigBuilder.dnsConfig(profile: profile)
            #expect(dns["strategy"] as? String == "prefer_ipv4",
                    "profile=\(profile) 必须 prefer_ipv4：原生 IPv6 宽带 + 无 v6 出口的 SS 机场，否则双栈站点全挂")
        }
    }
}
