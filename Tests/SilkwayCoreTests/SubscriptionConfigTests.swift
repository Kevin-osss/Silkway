import Testing
import Foundation
@testable import SilkwayCore

// MARK: - URI 解析

@Suite("订阅解析 - URI")
struct URIParserTests {

    @Test("解析 vmess://BASE64")
    func parseVMess() {
        let json = """
        {"ps":"香港 01","add":"hk.example.com","port":443,"id":"uuid","aid":0,"net":"tcp","type":"none"}
        """
        let b64 = Data(json.utf8).base64EncodedString()
        let uri = "vmess://\(b64)"
        let nodes = SubscriptionParser.parse(uri)
        #expect(nodes.count == 1)
        #expect(nodes.first?.name == "香港 01")
        #expect(nodes.first?.server == "hk.example.com")
        #expect(nodes.first?.port == 443)
        #expect(nodes.first?.proxyProtocol == .vmess)
        #expect(nodes.first?.countryCode == "HK")
    }

    @Test("解析 vless://")
    func parseVLESS() {
        let uri = "vless://uuid@jp.example.com:443?security=reality&sni=example.com#日本 东京"
        let nodes = SubscriptionParser.parse(uri)
        #expect(nodes.count == 1)
        #expect(nodes.first?.name == "日本 东京")
        #expect(nodes.first?.server == "jp.example.com")
        #expect(nodes.first?.port == 443)
        #expect(nodes.first?.proxyProtocol == .vless)
        #expect(nodes.first?.countryCode == "JP")
    }

    @Test("解析 trojan://")
    func parseTrojan() {
        let uri = "trojan://password@sg.example.com:443?security=tls#新加坡 中转"
        let nodes = SubscriptionParser.parse(uri)
        #expect(nodes.count == 1)
        #expect(nodes.first?.proxyProtocol == .trojan)
        #expect(nodes.first?.countryCode == "SG")
    }

    @Test("解析 ss://")
    func parseSS() {
        // 2022-blake3-aes-128-gcm:password@us.example.com:8388
        let plain = "2022-blake3-aes-128-gcm:password@us.example.com:8388"
        let b64 = Data(plain.utf8).base64EncodedString()
        let uri = "ss://\(b64)#美国 洛杉矶"
        let nodes = SubscriptionParser.parse(uri)
        #expect(nodes.count == 1)
        #expect(nodes.first?.name == "美国 洛杉矶")
        #expect(nodes.first?.server == "us.example.com")
        #expect(nodes.first?.port == 8388)
        #expect(nodes.first?.proxyProtocol == .shadowsocks)
        #expect(nodes.first?.countryCode == "US")
    }

    @Test("解析 hysteria2://")
    func parseHysteria2() {
        let uri = "hysteria2://pwd@de.example.com:443#德国 法兰克福"
        let nodes = SubscriptionParser.parse(uri)
        #expect(nodes.count == 1)
        #expect(nodes.first?.proxyProtocol == .hysteria2)
        #expect(nodes.first?.countryCode == "DE")
    }

    @Test("整段 Base64 编码的多行 URI")
    func parseWrappedBase64() {
        let lines = [
            "trojan://pwd@hk.example.com:443#香港 A",
            "trojan://pwd@jp.example.com:443#日本 B"
        ]
        let wrapped = Data(lines.joined(separator: "\n").utf8).base64EncodedString()
        let nodes = SubscriptionParser.parse(wrapped)
        #expect(nodes.count == 2)
    }
}

// MARK: - YAML / JSON

@Suite("订阅解析 - 批量格式")
struct BulkParserTests {

    @Test("解析 SIP008 JSON")
    func parseSIP008() {
        let json = """
        {
          "servers": [
            {"server": "sg.example.com", "server_port": 443, "password": "x", "method": "aes-256-gcm", "remarks": "新加坡"}
          ]
        }
        """
        let nodes = SubscriptionParser.parse(json)
        #expect(nodes.count == 1)
        #expect(nodes.first?.name == "新加坡")
        #expect(nodes.first?.proxyProtocol == .shadowsocks)
    }

    @Test("sing-box 完整 outbound 原样直通（vless/trojan 凭证不丢）")
    func singBoxOutboundsPassthrough() {
        // 机场可能直接给完整 sing-box 配置的 outbounds 数组
        let json = """
        {
          "outbounds": [
            {"type": "selector", "tag": "select", "outbounds": ["节点A"]},
            {"type": "vless", "tag": "日本 VLESS", "server": "jp.example.com", "server_port": 443,
             "uuid": "22222222-3333-4444-5555-666666666666",
             "tls": {"enabled": true, "server_name": "jp.example.com",
                     "reality": {"enabled": true, "public_key": "PXScH5cpX7GItYuQdbGqwCzMB3cynRBrtKIE089M_jU"}}},
            {"type": "trojan", "tag": "香港 Trojan", "server": "hk.example.com", "server_port": 8443,
             "password": "trojan-pw", "tls": {"enabled": true, "server_name": "hk.example.com"}},
            {"type": "shadowsocks", "tag": "美国 SS", "server": "us.example.com", "server_port": 8388,
             "method": "aes-128-gcm", "password": "ss-pw"}
          ]
        }
        """
        let nodes = SubscriptionParser.parse(json)
        // selector 没有 server 字段，应被跳过
        #expect(nodes.count == 3)

        // 三个协议都应有完整 outboundJSON（直通）
        for node in nodes {
            #expect(node.outboundJSON != nil, "\(node.name) 的 outboundJSON 不应为 nil")
        }

        // vless 直通应保留 reality 配置（凭证不丢的核心证据）
        let vless = nodes.first { $0.proxyProtocol == .vless }
        #expect(vless != nil)
        if let json = vless?.outboundJSON,
           let dict = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let tls = dict["tls"] as? [String: Any],
           let reality = tls["reality"] as? [String: Any] {
            #expect(reality["public_key"] as? String == "PXScH5cpX7GItYuQdbGqwCzMB3cynRBrtKIE089M_jU")
        } else {
            Issue.record("vless outbound 缺少 tls.reality 配置")
        }

        // trojan 直通应保留 password
        let trojan = nodes.first { $0.proxyProtocol == .trojan }
        #expect(trojan?.outboundJSON?.contains("trojan-pw") == true)
    }

    @Test("解析 Clash YAML proxies 子集")
    func parseClashYAML() {
        let yaml = """
        proxies:
          - {name: 香港 IEPL, server: hk.example.com, port: 443, type: trojan}
          - name: 日本 BGP
            server: jp.example.com
            port: 8443
            type: vmess
        rules:
          - DOMAIN,example.com,PROXY
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 2)
        #expect(nodes.first?.name == "香港 IEPL")
        #expect(nodes.first?.proxyProtocol == .trojan)
        #expect(nodes.last?.name == "日本 BGP")
        #expect(nodes.last?.proxyProtocol == .vmess)
    }
}

// MARK: - ConfigBuilder

@Suite("配置生成")
struct ConfigBuilderTests {

    @Test("至少生成 direct-out 和 PROXY selector")
    func basicConfig() throws {
        let nodes: [ProxyNode] = [
            ProxyNode(name: "香港 01", server: "hk.example.com", port: 443, proxyProtocol: .trojan)
        ]
        let dict = ConfigBuilder.build(nodes: nodes, apiPort: 9090, mixedPort: 2080)
        #expect(dict["inbounds"] != nil)
        #expect(dict["route"] != nil)

        let outbounds = dict["outbounds"] as? [[String: Any]]
        #expect(outbounds?.contains(where: { $0["tag"] as? String == "PROXY" }) == true)
        #expect(outbounds?.contains(where: { $0["tag"] as? String == "direct-out" }) == true)

        // 检查 clash_api 格式正确
        let experimental = dict["experimental"] as? [String: Any]
        let clashAPI = experimental?["clash_api"] as? [String: Any]
        #expect(clashAPI?["external_controller"] as? String == "127.0.0.1:9090")
    }

    @Test("直连模式下 final 为 direct-out")
    func directMode() {
        var cfg = AppConfig()
        cfg.mode = .direct
        let dict = ConfigBuilder.build(nodes: [], config: cfg, apiPort: 9090, mixedPort: 2080)
        let route = dict["route"] as? [String: Any]
        #expect(route?["final"] as? String == "direct-out")
    }

    @Test("生成的配置可被 JSONSerialization 序列化")
    func serializable() throws {
        let nodes = [
            ProxyNode(name: "香港 01", server: "hk.example.com", port: 443, proxyProtocol: .trojan)
        ]
        let data = try ConfigBuilder.data(nodes: nodes, apiPort: 9090, mixedPort: 2080)
        #expect(data.count > 0)
        let roundTrip = try JSONSerialization.jsonObject(with: data)
        #expect(roundTrip is [String: Any])
    }
}
