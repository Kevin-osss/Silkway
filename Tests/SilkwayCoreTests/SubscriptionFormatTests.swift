import Foundation
import Testing
@testable import SilkwayCore

/// 订阅格式通用性测试。
///
/// 核心断言不是「解析出几个节点」，而是「每个节点都能生成可用的 outbound」——
/// 早期的 Clash YAML 解析器能解析出节点名和端口，但没有凭证，
/// ConfigBuilder 会静默丢弃它们：UI 上看得见节点，连接时却没有对应出站。
/// 这类「假装成功」的 bug 只能靠端到端断言抓住。
@Suite("订阅格式通用性")
struct SubscriptionFormatTests {

    // MARK: - Clash YAML

    /// 块式缩进 + 嵌套 ws-opts —— 机场 Clash 订阅最主流的写法
    @Test("Clash YAML：vmess + ws + tls 完整凭证")
    func clashVMessWebSocket() throws {
        let yaml = """
        port: 7890
        proxies:
          - name: "🇭🇰 香港 01"
            type: vmess
            server: hk01.example.com
            port: 443
            uuid: b831381d-6324-4d53-ad4f-8cda48b30811
            alterId: 0
            cipher: auto
            tls: true
            servername: hk01.example.com
            skip-cert-verify: false
            network: ws
            ws-opts:
              path: /v2ray/path
              headers:
                Host: hk01.example.com
        proxy-groups:
          - name: PROXY
        """

        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 1)

        let node = try #require(nodes.first)
        #expect(node.name == "🇭🇰 香港 01")
        #expect(node.proxyProtocol == .vmess)
        #expect(node.countryCode == "HK")

        // 关键：凭证必须完整地进到 outbound
        let out = try requireOutbound(node)
        #expect(out["type"] as? String == "vmess")
        #expect(out["uuid"] as? String == "b831381d-6324-4d53-ad4f-8cda48b30811")
        #expect(out["alter_id"] as? Int == 0)

        let tls = try #require(out["tls"] as? [String: Any])
        #expect(tls["enabled"] as? Bool == true)
        #expect(tls["server_name"] as? String == "hk01.example.com")

        let transport = try #require(out["transport"] as? [String: Any])
        #expect(transport["type"] as? String == "ws")
        #expect(transport["path"] as? String == "/v2ray/path")
        let headers = try #require(transport["headers"] as? [String: Any])
        #expect(headers["Host"] as? String == "hk01.example.com")
    }

    @Test("Clash YAML：ss 带 obfs 插件")
    func clashShadowsocksPlugin() throws {
        let yaml = """
        proxies:
          - name: 日本节点
            type: ss
            server: jp.example.com
            port: 8388
            cipher: aes-256-gcm
            password: "p@ss:word#1"
            plugin: obfs
            plugin-opts:
              mode: http
              host: bing.com
        """

        let nodes = SubscriptionParser.parse(yaml)
        let node = try #require(nodes.first)
        let out = try requireOutbound(node)

        #expect(out["type"] as? String == "shadowsocks")
        #expect(out["method"] as? String == "aes-256-gcm")
        // 密码含冒号和井号 —— 不能被注释剥离逻辑或分隔逻辑破坏
        #expect(out["password"] as? String == "p@ss:word#1")
        #expect(out["plugin"] as? String == "obfs-local")
        let opts = try #require(out["plugin_opts"] as? String)
        #expect(opts.contains("obfs=http"))
        #expect(opts.contains("obfs-host=bing.com"))
    }

    @Test("Clash YAML：内联流式写法 + 嵌套")
    func clashInlineFlow() throws {
        let yaml = """
        proxies:
          - {name: 美国, type: trojan, server: us.example.com, port: 443, password: trojan-pw, sni: us.example.com}
          - {name: 新加坡, type: vless, server: sg.example.com, port: 443, uuid: 11111111-2222-3333-4444-555555555555, tls: true, network: ws, ws-opts: {path: /ws, headers: {Host: sg.example.com}}}
        """

        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 2)

        let trojan = try requireOutbound(try #require(nodes.first))
        #expect(trojan["type"] as? String == "trojan")
        #expect(trojan["password"] as? String == "trojan-pw")
        // trojan 强制 TLS：Clash 不写 tls: true 也必须生成
        let trojanTLS = try #require(trojan["tls"] as? [String: Any])
        #expect(trojanTLS["server_name"] as? String == "us.example.com")

        let vless = try requireOutbound(nodes[1])
        #expect(vless["type"] as? String == "vless")
        #expect(vless["uuid"] as? String == "11111111-2222-3333-4444-555555555555")
        let transport = try #require(vless["transport"] as? [String: Any])
        #expect(transport["path"] as? String == "/ws")
        let headers = try #require(transport["headers"] as? [String: Any])
        #expect(headers["Host"] as? String == "sg.example.com")
    }

    @Test("Clash YAML：VLESS REALITY 补齐 utls")
    func clashRealityFillsUTLS() throws {
        let yaml = """
        proxies:
          - name: Reality节点
            type: vless
            server: re.example.com
            port: 443
            uuid: 99999999-8888-7777-6666-555555555555
            tls: true
            flow: xtls-rprx-vision
            reality-opts:
              public-key: xxxxPUBKEYxxxx
              short-id: abcd1234
        """

        let node = try #require(SubscriptionParser.parse(yaml).first)
        let out = try requireOutbound(node)
        #expect(out["flow"] as? String == "xtls-rprx-vision")

        let tls = try #require(out["tls"] as? [String: Any])
        let reality = try #require(tls["reality"] as? [String: Any])
        #expect(reality["public_key"] as? String == "xxxxPUBKEYxxxx")
        #expect(reality["short_id"] as? String == "abcd1234")
        // sing-box 的 reality 必须配 utls，Clash 不写时要自动补
        let utls = try #require(tls["utls"] as? [String: Any])
        #expect(utls["enabled"] as? Bool == true)
    }

    @Test("Clash YAML：不支持的协议整条丢弃而非降级")
    func clashUnsupportedProtocolDropped() throws {
        let yaml = """
        proxies:
          - {name: SSR节点, type: ssr, server: a.example.com, port: 443, cipher: aes-256-cfb, password: pw, protocol: auth_aes128_md5, obfs: tls1.2_ticket_auth}
          - {name: 正常节点, type: ss, server: b.example.com, port: 8388, cipher: aes-256-gcm, password: pw2}
        """

        let nodes = SubscriptionParser.parse(yaml)
        // ssr 不该被伪装成 shadowsocks —— 那会造出一个连不上的节点
        #expect(nodes.count == 1)
        #expect(nodes.first?.name == "正常节点")
    }

    @Test("Clash YAML：字段内的嵌套列表不会截断节点")
    func clashNestedListInsideItem() throws {
        // 列表项内部的 `- h2` 不能被当成新节点：
        // 早期实现只看行首是否 "- "，把 2 个节点解成 4 个条目，
        // 中间两个是只有碎片字段的垃圾条目，且 alpn 整个丢失。
        let yaml = """
        proxies:
          - name: 节点A
            type: trojan
            server: a.example.com
            port: 443
            password: pw-a
            alpn:
              - h2
              - http/1.1
            sni: a.example.com
          - name: 节点B
            type: trojan
            server: b.example.com
            port: 443
            password: pw-b
        """

        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 2, "嵌套列表不应把节点截成多段")
        #expect(nodes.first?.name == "节点A")
        #expect(nodes.last?.name == "节点B")

        // alpn 必须进到 tls 里，不能因为解析断层而丢失
        let out = try requireOutbound(try #require(nodes.first))
        let tls = try #require(out["tls"] as? [String: Any])
        let alpn = try #require(tls["alpn"] as? [String])
        #expect(alpn == ["h2", "http/1.1"])
        #expect(tls["server_name"] as? String == "a.example.com")

        // 第二个节点的凭证不能被第一个污染
        let out2 = try requireOutbound(nodes[1])
        #expect(out2["password"] as? String == "pw-b")
    }

    // MARK: - YAML 写法差异（2026-09-09 代码审查发现的真实缺陷）

    @Test("顶格序列：列表项与 proxies 同列")
    func clashTopLevelSequence() throws {
        // YAML 允许序列项与父 key 同列，早期实现把「缩进 0 且非空」当块结束，
        // 这种完全合法的写法会解析出 0 个节点。
        let yaml = """
        proxies:
        - name: 节点A
          type: ss
          server: a.example.com
          port: 8388
          cipher: aes-256-gcm
          password: pw-a
        - name: 节点B
          type: ss
          server: b.example.com
          port: 8389
          cipher: aes-256-gcm
          password: pw-b
        rules:
          - MATCH,DIRECT
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 2)
        #expect(nodes.first?.name == "节点A")
        let out = try requireOutbound(try #require(nodes.last))
        #expect(out["password"] as? String == "pw-b")
    }

    @Test("proxy-groups 排在 proxies 之前不能抓错块")
    func clashProxyGroupsBeforeProxies() throws {
        // 策略组内部也有 `proxies:` 字段（值是节点名列表），
        // 不看缩进的话会先命中它，真正的节点定义永远读不到。
        let yaml = """
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - 香港
              - 日本
        proxies:
          - {name: 香港, type: ss, server: hk.example.com, port: 8388, cipher: aes-256-gcm, password: hk-pw}
          - {name: 日本, type: ss, server: jp.example.com, port: 8388, cipher: aes-256-gcm, password: jp-pw}
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 2)
        #expect(nodes.map(\.name).sorted() == ["日本", "香港"])
        let out = try requireOutbound(try #require(nodes.first { $0.name == "香港" }))
        #expect(out["password"] as? String == "hk-pw")
    }

    @Test("序列项的 - 单独占一行")
    func clashBareDashItem() throws {
        let yaml = """
        proxies:
          -
            name: 节点A
            type: trojan
            server: a.example.com
            port: 443
            password: pw-a
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 1, "字段写在下一行的写法不能让节点凭空消失")
        let out = try requireOutbound(try #require(nodes.first))
        #expect(out["password"] as? String == "pw-a")
    }

    @Test("单行流式列表 proxies: [{...}]")
    func clashInlineFlowSequence() throws {
        let yaml = """
        proxies: [{name: A, type: ss, server: a.com, port: 8388, cipher: aes-256-gcm, password: pw-a}, {name: B, type: trojan, server: b.com, port: 443, password: pw-b}]
        rules: []
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 2)
        #expect(nodes.first?.proxyProtocol == .shadowsocks)
        #expect(nodes.last?.proxyProtocol == .trojan)
    }

    @Test("引号值带行尾注释：引号必须脱干净")
    func clashQuotedValueWithComment() throws {
        // 早期实现先判首尾引号再剥注释，导致值变成 "\"a.com\""；
        // tls: "true" # x 更致命 —— bool 解析失败使整个 tls 块被丢弃。
        let yaml = """
        proxies:
          - name: "节点A"   # 主力节点
            type: vmess
            server: "a.example.com"  # 香港机房
            port: 443
            uuid: "11111111-2222-3333-4444-555555555555"  # 客户 ID
            alterId: 0
            cipher: auto
            tls: "true"   # 开启 TLS
            servername: "a.example.com"
        """
        let node = try #require(SubscriptionParser.parse(yaml).first)
        #expect(node.name == "节点A")
        #expect(node.server == "a.example.com", "引号必须脱掉")

        let out = try requireOutbound(node)
        #expect(out["uuid"] as? String == "11111111-2222-3333-4444-555555555555")
        let tls = try #require(out["tls"] as? [String: Any], "tls: \"true\" + 注释 不能导致 tls 块丢失")
        #expect(tls["enabled"] as? Bool == true)
        #expect(tls["server_name"] as? String == "a.example.com")
    }

    @Test("reality-opts 存在但未写 tls: true")
    func clashRealityWithoutExplicitTLS() throws {
        let yaml = """
        proxies:
          - name: Reality
            type: vless
            server: re.example.com
            port: 443
            uuid: 99999999-8888-7777-6666-555555555555
            flow: xtls-rprx-vision
            servername: www.microsoft.com
            reality-opts:
              public-key: PXScH5cpX7GItYuQdbGqwCzMB3cynRBrtKIE089M_jU
              short-id: 6ba85179e30d4fc2
        """
        let out = try requireOutbound(try #require(SubscriptionParser.parse(yaml).first))
        let tls = try #require(out["tls"] as? [String: Any], "有 reality-opts 就必须启用 TLS")
        let reality = try #require(tls["reality"] as? [String: Any])
        #expect(reality["public_key"] as? String == "PXScH5cpX7GItYuQdbGqwCzMB3cynRBrtKIE089M_jU")
        #expect(tls["server_name"] as? String == "www.microsoft.com")
    }

    @Test("块序列与 key 同缩进")
    func clashSameIndentBlockSequence() throws {
        let yaml = """
        proxies:
          - name: TUIC节点
            type: tuic
            server: t.example.com
            port: 443
            uuid: 33333333-4444-5555-6666-777777777777
            password: tuic-pw
            alpn:
            - h3
            sni: t.example.com
        """
        let out = try requireOutbound(try #require(SubscriptionParser.parse(yaml).first))
        let tls = try #require(out["tls"] as? [String: Any])
        #expect(tls["alpn"] as? [String] == ["h3"], "同缩进的块序列不能静默丢失")
    }

    @Test("带宽单位换算含小数")
    func clashBandwidthDecimal() throws {
        func upMbps(_ raw: String) throws -> Int {
            let yaml = """
            proxies:
              - {name: HY2, type: hysteria2, server: h.com, port: 443, password: pw, up: "\(raw)", down: "\(raw)"}
            """
            let out = try requireOutbound(try #require(SubscriptionParser.parse(yaml).first))
            return out["up_mbps"] as? Int ?? -1
        }

        #expect(try upMbps("100 Mbps") == 100)
        #expect(try upMbps("1 Gbps") == 1000)
        #expect(try upMbps("0.5 Gbps") == 500, "小数不能被吃掉")
        #expect(try upMbps("1.5 Gbps") == 1500)
    }

    // MARK: - 端到端：解析结果必须能进配置

    @Test("Clash YAML 节点能进入最终 sing-box 配置")
    func clashNodesReachFinalConfig() throws {
        let yaml = """
        proxies:
          - {name: A, type: ss, server: a.com, port: 8388, cipher: aes-256-gcm, password: pw}
          - {name: B, type: trojan, server: b.com, port: 443, password: pw2}
          - {name: C, type: vmess, server: c.com, port: 443, uuid: 11111111-2222-3333-4444-555555555555}
        """

        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 3)

        let data = try ConfigBuilder.data(nodes: nodes, apiPort: 19099, mixedPort: 17899)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try #require(dict["outbounds"] as? [[String: Any]])

        // 三个节点出站 + direct + 策略组，节点一个都不能少
        let tags = outbounds.compactMap { $0["tag"] as? String }
        #expect(tags.contains("A"))
        #expect(tags.contains("B"))
        #expect(tags.contains("C"))
    }

    // MARK: - 其他格式回归

    @Test("分享链接：hysteria2 / vless / ss 混合")
    func mixedShareLinks() throws {
        let text = """
        ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@ss.example.com:8388#SS节点
        vless://11111111-2222-3333-4444-555555555555@vless.example.com:443?security=tls&sni=vless.example.com&type=ws&path=%2Fws#VLESS节点
        hysteria2://password123@hy2.example.com:443?sni=hy2.example.com#HY2节点
        """

        let nodes = SubscriptionParser.parse(text)
        #expect(nodes.count == 3)
        for node in nodes {
            _ = try requireOutbound(node)  // 每个都必须有可用出站
        }
    }

    // MARK: - 辅助

    private func requireOutbound(_ node: ProxyNode) throws -> [String: Any] {
        let json = try #require(node.outboundJSON, "节点 \(node.name) 没有 outboundJSON —— 会被 ConfigBuilder 静默丢弃")
        let data = try #require(json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
