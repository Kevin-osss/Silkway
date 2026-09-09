import Foundation
import Testing
@testable import SilkwayCore

/// 配置持久化的向前/向后兼容测试。
///
/// 背景：AppConfigStore 用 `try? decode` 加载配置，解码失败会静默回退到全默认值。
/// 而 Swift 合成的 Decodable 遇到缺失的 key 直接抛 keyNotFound（属性默认值救不了）。
/// 两者叠加 = 每次新增配置字段，所有老用户的设置全部静默重置。
/// 这类 bug 不会崩溃、不报错，只是「用户的设置莫名其妙没了」。
@Suite("配置持久化兼容性")
struct ConfigCompatibilityTests {

    @Test("旧版配置缺少新字段仍能解码，且保留原有设置")
    func oldConfigDecodesWithNewFields() throws {
        // 模拟一份「新增 subscriptionUserAgent 之前」写入的配置，
        // 用户在里面开了 TUN、关了系统代理、开了开机自启
        let oldJSON = """
        {
          "launchAtLogin": true,
          "autoConnectOnLaunch": true,
          "silentLaunch": false,
          "mode": "rule",
          "systemProxyEnabled": false,
          "tunEnabled": true,
          "showSpeedInMenuBar": true,
          "latencyTestURL": "http://cp.cloudflare.com/generate_204",
          "latencyTestTimeout": 5,
          "latencyTestConcurrency": 10,
          "bypassChinaMainland": true,
          "customDirectDomains": ["internal.corp"],
          "dnsProfile": "system"
        }
        """
        let data = try #require(oldJSON.data(using: .utf8))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        // 用户的设置必须原样保留 —— 这才是这个测试的意义
        #expect(config.launchAtLogin == true)
        #expect(config.tunEnabled == true)
        #expect(config.systemProxyEnabled == false)
        #expect(config.bypassChinaMainland == true)
        #expect(config.customDirectDomains == ["internal.corp"])

        // 缺失的新字段取默认值
        #expect(config.subscriptionUserAgent == "sing-box/1.13.19")
    }

    @Test("极简配置（只有一个字段）也能解码")
    func minimalConfigDecodes() throws {
        let data = try #require(#"{"tunEnabled": true}"#.data(using: .utf8))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config.tunEnabled == true)
        #expect(config.mode == .rule)              // 默认值
        #expect(config.bypassChinaMainland == true) // 默认值
    }

    @Test("空对象解码为全默认配置")
    func emptyObjectDecodes() throws {
        let data = try #require("{}".data(using: .utf8))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config == AppConfig())
    }

    @Test("编码后再解码保持一致")
    func roundTrip() throws {
        var config = AppConfig()
        config.tunEnabled = true
        config.subscriptionUserAgent = "clash-verge/1.5.0"
        config.customDirectDomains = ["a.com", "b.com"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == config)
    }

    // MARK: - Subscription

    @Test("旧版订阅数据缺少流量字段仍能解码")
    func oldSubscriptionDecodes() throws {
        let oldJSON = """
        {
          "id": "550E8400-E29B-41D4-A716-446655440000",
          "name": "我的机场",
          "url": "https://sub.example.com/link?token=abc",
          "nodeCount": 42
        }
        """
        let data = try #require(oldJSON.data(using: .utf8))
        let sub = try JSONDecoder().decode(Subscription.self, from: data)

        #expect(sub.name == "我的机场")
        #expect(sub.nodeCount == 42)
        // 新增字段全为 nil，不影响加载
        #expect(sub.skippedCount == nil)
        #expect(sub.trafficTotal == nil)
        #expect(sub.expiresAt == nil)
    }

    @Test("流量计算：已用 / 剩余 / 比例")
    func trafficMath() throws {
        var sub = Subscription(name: "测试", url: URL(string: "https://a.com")!)
        sub.trafficUpload = 10_000_000_000       // 10 GB
        sub.trafficDownload = 40_000_000_000     // 40 GB
        sub.trafficTotal = 100_000_000_000       // 100 GB

        #expect(sub.trafficUsed == 50_000_000_000)
        #expect(sub.trafficRemaining == 50_000_000_000)
        #expect(sub.trafficRatio == 0.5)
    }

    @Test("流量总量为 0 表示不限量")
    func unlimitedTraffic() throws {
        var sub = Subscription(name: "测试", url: URL(string: "https://a.com")!)
        sub.trafficUpload = 1_000
        sub.trafficDownload = 2_000
        sub.trafficTotal = 0

        #expect(sub.trafficUsed == 3_000)
        #expect(sub.trafficRemaining == nil, "不限量时不应算出剩余值")
        #expect(sub.trafficRatio == nil)
    }

    // MARK: - Subscription-Userinfo 响应头

    @Test("解析机场返回的流量头")
    func parseUserInfoHeader() throws {
        var sub = Subscription(name: "测试", url: URL(string: "https://a.com")!)
        sub.applyUserInfo(header: "upload=10000000000; download=40000000000; total=100000000000; expire=1767225600")

        #expect(sub.trafficUpload == 10_000_000_000)
        #expect(sub.trafficDownload == 40_000_000_000)
        #expect(sub.trafficTotal == 100_000_000_000)
        #expect(sub.trafficUsed == 50_000_000_000)
        #expect(sub.expiresAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("流量头的宽松格式：缺字段 / 无空格 / expire=0")
    func parseUserInfoHeaderVariants() throws {
        // 无空格 + 缺 expire
        var a = Subscription(name: "A", url: URL(string: "https://a.com")!)
        a.applyUserInfo(header: "upload=1;download=2;total=3")
        #expect(a.trafficUsed == 3)
        #expect(a.expiresAt == nil)

        // expire=0 表示不过期，不能算成 1970 年
        var b = Subscription(name: "B", url: URL(string: "https://b.com")!)
        b.applyUserInfo(header: "upload=1; download=2; total=0; expire=0")
        #expect(b.expiresAt == nil, "expire=0 不该变成 1970 年到期")

        // 完全无法解析的内容不该清掉已有数据
        var c = Subscription(name: "C", url: URL(string: "https://c.com")!)
        c.trafficTotal = 999
        c.applyUserInfo(header: "garbage")
        #expect(c.trafficTotal == 999)
    }

    // MARK: - 解析丢弃上报

    @Test("不支持的条目会被计数并附原因")
    func skippedEntriesReported() throws {
        let yaml = """
        proxies:
          - {name: 正常, type: ss, server: a.com, port: 8388, cipher: aes-256-gcm, password: pw}
          - {name: SSR节点, type: ssr, server: b.com, port: 443, password: pw}
          - {name: Snell节点, type: snell, server: c.com, port: 443, psk: pw}
          - {name: 缺密码, type: trojan, server: d.com, port: 443}
        """
        let result = SubscriptionParser.parseDetailed(yaml)

        #expect(result.nodes.count == 1)
        #expect(result.skippedCount == 3)
        // 原因里要带节点名，否则用户不知道是哪个没导入
        #expect(result.skipped.contains { $0.contains("SSR节点") })
        #expect(result.skipped.contains { $0.contains("缺密码") })
    }
}
