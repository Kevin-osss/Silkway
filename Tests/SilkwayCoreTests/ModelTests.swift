import Testing
import Foundation
@testable import SilkwayCore

// MARK: - 延迟分级边界

@Suite("延迟分级")
struct LatencyLevelTests {

    private func node(latency: Int?, tested: Bool = true) -> ProxyNode {
        ProxyNode(name: "t", server: "1.1.1.1", port: 443,
                  proxyProtocol: .trojan, latency: latency, hasBeenTested: tested)
    }

    @Test("阈值边界：199/200 分属 good/fair")
    func goodFairBoundary() {
        #expect(node(latency: 199).latencyLevel == .good)
        #expect(node(latency: 200).latencyLevel == .fair)
    }

    @Test("阈值边界：500/501 分属 fair/poor")
    func fairPoorBoundary() {
        // 手册写的是「200–500ms 可用」，500 属于闭区间内，应为 fair
        #expect(node(latency: 500).latencyLevel == .fair)
        #expect(node(latency: 501).latencyLevel == .poor)
    }

    @Test("未测速与超时必须可区分")
    func untestedVsTimeout() {
        #expect(node(latency: nil, tested: false).latencyLevel == .untested)
        #expect(node(latency: nil, tested: true).latencyLevel == .timeout)
        // 两者 UI 都是灰色，但文案不同
        #expect(node(latency: nil, tested: false).displayLatency == "—")
        #expect(node(latency: nil, tested: true).displayLatency == "超时")
    }

    @Test("延迟文案带单位")
    func displayText() {
        #expect(node(latency: 42).displayLatency == "42 ms")
    }
}

// MARK: - 订阅

@Suite("订阅")
struct SubscriptionTests {

    @Test("URL 脱敏：所有查询参数值都打码")
    func maskURL() throws {
        let sub = Subscription(
            name: "Aurora",
            url: try #require(URL(string: "https://sub.aurora.net/link?token=SECRET123&uid=42"))
        )
        let masked = sub.maskedURL
        #expect(!masked.contains("SECRET123"))
        #expect(!masked.contains("42"))
        // URLComponents 会对非 ASCII 做 percent-encoding，所以 bullet 会变成 %E2%80%A6
        // 这里只验证：解码后不存在原始 token，且 token 参数仍在
        if let decoded = masked.removingPercentEncoding {
            #expect(decoded.contains("token=•••"))
        }
        #expect(masked.contains("sub.aurora.net"))
    }

    @Test("无查询参数的 URL 保持原样")
    func maskURLNoQuery() throws {
        let sub = Subscription(
            name: "自建",
            url: try #require(URL(string: "file:///Users/lin/.config/sing-box/self.json"))
        )
        #expect(sub.maskedURL.contains("self.json"))
    }

    @Test("从未更新过则需要更新")
    func needsUpdateWhenNever() {
        var sub = Subscription(name: "x", url: URL(string: "https://a.com")!)
        sub.updateInterval = 3600
        #expect(sub.needsUpdate())
    }

    @Test("未设置间隔则从不自动更新")
    func neverUpdateWithoutInterval() {
        let sub = Subscription(name: "x", url: URL(string: "https://a.com")!)
        #expect(!sub.needsUpdate())
    }

    @Test("按间隔判断是否到期")
    func updateByInterval() {
        let now = Date()
        var sub = Subscription(name: "x", url: URL(string: "https://a.com")!)
        sub.updateInterval = 3600
        sub.lastUpdated = now.addingTimeInterval(-3599)
        #expect(!sub.needsUpdate(now: now))
        sub.lastUpdated = now.addingTimeInterval(-3601)
        #expect(sub.needsUpdate(now: now))
    }
}

// MARK: - 连接

@Suite("连接")
struct ConnectionTests {

    @Test("chains 是倒序的，实际出站取第一个")
    func chainsOrdering() {
        let c = Connection(
            id: "1", host: "github.com", destinationPort: 443,
            network: "TCP", rule: "DOMAIN-SUFFIX", rulePayload: "github.com",
            chains: ["香港 IEPL 01", "PROXY"],   // Clash API 返回顺序：出站在前
            uploadBytes: 100, downloadBytes: 900,
            startTime: Date()
        )
        #expect(c.actualOutbound == "香港 IEPL 01")
        #expect(c.totalBytes == 1000)
    }
}

// MARK: - 策略组

@Suite("策略组")
struct ProxyGroupTests {

    @Test("Clash 类型名转换为 sing-box 类型")
    func clashTypeMapping() {
        #expect(GroupType.fromClashType("url-test") == .urltest)
        #expect(GroupType.fromClashType("select") == .selector)
        #expect(GroupType.fromClashType("load-balance") == .loadBalance)
        #expect(GroupType.fromClashType("fallback") == .fallback)
        #expect(GroupType.fromClashType("unknown") == nil)
    }

    @Test("sing-box 的 urltest 无连字符")
    func singboxRawValue() {
        // 写成 "url-test" 会让生成的配置被 sing-box 拒绝
        #expect(GroupType.urltest.rawValue == "urltest")
    }

    @Test("自动类型的组不可手动选择")
    func selectability() {
        let auto = ProxyGroup(name: "自动", type: .urltest, tag: "auto")
        let manual = ProxyGroup(name: "手动", type: .selector, tag: "manual")
        #expect(!auto.isUserSelectable)
        #expect(manual.isUserSelectable)
    }
}

// MARK: - 编解码往返

@Suite("持久化")
struct CodableTests {

    @Test("ProxyNode 编解码往返一致")
    func nodeRoundTrip() throws {
        let original = ProxyNode(
            name: "香港 IEPL 01 · 专线", server: "hk.example.com", port: 443,
            proxyProtocol: .hysteria2, countryCode: "HK", latency: 42, hasBeenTested: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxyNode.self, from: data)
        #expect(decoded == original)
    }

    @Test("AppConfig 默认值可编解码")
    func configRoundTrip() throws {
        let data = try JSONEncoder().encode(AppConfig())
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.mode == .rule)
        #expect(decoded.systemProxyEnabled)
        #expect(!decoded.tunEnabled)
    }

    @Test("ProxyMode 用英文 rawValue 持久化")
    func modeRawValue() {
        // 中文 rawValue 会在 i18n 时破坏已存档的配置
        #expect(ProxyMode.rule.rawValue == "rule")
        #expect(ProxyMode.rule.displayName == "规则")
    }
}
