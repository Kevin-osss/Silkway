import Foundation
import Testing
@testable import SilkwayCore

/// Clash 规则语法 → sing-box route.rules 的转换测试。
///
/// 这是完整配置导入中风险最高的一步：转换错了不报错，配置能过
/// sing-box check，但分流结果全错。所以每种规则类型都要有断言，
/// 且最终生成的完整配置必须过真实 sing-box check。
@Suite("Clash 规则转换")
struct ClashRuleConverterTests {

    /// 默认的目标解析：只认 DIRECT/REJECT，其余原样透传
    private let resolve: (String) -> String? = { raw in
        ClashRuleConverter.resolveClashTarget(raw, knownGroups: [])
    }

    @Test("DOMAIN-SUFFIX 转换")
    func domainSuffix() throws {
        let outcome = ClashRuleConverter.convert(
            "DOMAIN-SUFFIX,google.com,PROXY", resolveTarget: resolve
        )
        guard case .rule(let rule) = outcome else { Issue.record("应产出规则"); return }
        #expect(rule["domain_suffix"] as? [String] == ["google.com"])
        #expect(rule["outbound"] as? String == "PROXY")
        #expect(rule["action"] as? String == "route")
    }

    @Test("DOMAIN 与 DOMAIN-KEYWORD")
    func domainAndKeyword() throws {
        let domain = ClashRuleConverter.convert("DOMAIN,api.openai.com,PROXY", resolveTarget: resolve)
        guard case .rule(let r1) = domain else { Issue.record("DOMAIN 应产出规则"); return }
        #expect(r1["domain"] as? [String] == ["api.openai.com"])

        let keyword = ClashRuleConverter.convert("DOMAIN-KEYWORD,twitter,PROXY", resolveTarget: resolve)
        guard case .rule(let r2) = keyword else { Issue.record("DOMAIN-KEYWORD 应产出规则"); return }
        #expect(r2["domain_keyword"] as? [String] == ["twitter"])
    }

    @Test("IP-CIDR 带 no-resolve 选项")
    func ipCIDR() throws {
        let outcome = ClashRuleConverter.convert(
            "IP-CIDR,91.108.56.0/22,PROXY,no-resolve", resolveTarget: resolve
        )
        guard case .rule(let rule) = outcome else { Issue.record("应产出规则"); return }
        #expect(rule["ip_cidr"] as? [String] == ["91.108.56.0/22"])
        #expect(rule["outbound"] as? String == "PROXY")
    }

    @Test("SRC-IP-CIDR 与 DST-PORT")
    func sourceAndPort() throws {
        let src = ClashRuleConverter.convert("SRC-IP-CIDR,192.168.0.0/16,DIRECT", resolveTarget: resolve)
        guard case .rule(let r1) = src else { Issue.record("SRC-IP-CIDR 应产出规则"); return }
        #expect(r1["source_ip_cidr"] as? [String] == ["192.168.0.0/16"])
        #expect(r1["outbound"] as? String == "direct-out", "DIRECT 应映射到 direct-out")

        let port = ClashRuleConverter.convert("DST-PORT,25,REJECT", resolveTarget: resolve)
        guard case .rule(let r2) = port else { Issue.record("DST-PORT 应产出规则"); return }
        #expect(r2["port"] as? [Int] == [25])
        #expect(r2["outbound"] as? String == "REJECT", "REJECT 应映射到 REJECT block 出站")
    }

    @Test("GEOIP,CN 走 rule_set，其他国家跳过")
    func geoip() throws {
        let cn = ClashRuleConverter.convert("GEOIP,CN,DIRECT", resolveTarget: resolve)
        guard case .rule(let r1) = cn else { Issue.record("GEOIP,CN 应产出规则"); return }
        #expect(r1["rule_set"] as? [String] == ["geoip-cn"])

        // 本地没有 geoip-us 规则集文件，转成引用会让 sing-box 启动失败
        let us = ClashRuleConverter.convert("GEOIP,US,PROXY", resolveTarget: resolve)
        guard case .skipped(let reason) = us else { Issue.record("GEOIP,US 应跳过"); return }
        #expect(reason.contains("geoip-us") || reason.contains("规则集"))
    }

    @Test("MATCH 转成 final，不进入 rules 数组")
    func matchBecomesFinal() throws {
        let lines = [
            "DOMAIN-SUFFIX,example.com,PROXY",
            "MATCH,PROXY",
        ]
        let result = ClashRuleConverter.convertAll(lines, resolveTarget: resolve)
        #expect(result.rules.count == 1, "MATCH 不应出现在 rules 数组里")
        #expect(result.final == "PROXY")
        #expect(result.skipped.isEmpty)
    }

    @Test("不支持的规则类型跳过并记录原因")
    func unsupportedTypesSkipped() throws {
        let lines = [
            "PROCESS-NAME,Telegram,PROXY",
            "RULE-SET,myrules,PROXY",
            "IP-ASN,13335,PROXY",
        ]
        let result = ClashRuleConverter.convertAll(lines, resolveTarget: resolve)
        #expect(result.rules.isEmpty)
        #expect(result.skipped.count == 3)
        // 原因里要带规则原文，用户才知道是哪条没生效
        #expect(result.skipped.contains { $0.contains("PROCESS-NAME") })
    }

    @Test("目标解析失败不产出规则")
    func unresolvableTarget() throws {
        let outcome = ClashRuleConverter.convert("DOMAIN-SUFFIX,x.com,不存在的组", resolveTarget: { _ in nil })
        guard case .skipped = outcome else { Issue.record("目标无法解析时应跳过"); return }
    }

    // MARK: - proxy-groups 转换

    @Test("select 组与 url-test 组")
    func groups() throws {
        let select = ClashRuleConverter.groupOutbound(
            from: ["name": "PROXY", "type": "select", "proxies": ["香港01", "美国01"]],
            members: ["香港01", "美国01"]
        )
        #expect(select?["type"] as? String == "selector")
        #expect(select?["tag"] as? String == "PROXY")
        #expect(select?["outbounds"] as? [String] == ["香港01", "美国01"])

        let urltest = ClashRuleConverter.groupOutbound(
            from: [
                "name": "自动选择", "type": "url-test",
                "url": "http://cp.cloudflare.com/generate_204",
                "interval": "300", "tolerance": "50",
                "proxies": ["香港01"],
            ],
            members: ["香港01"]
        )
        #expect(urltest?["type"] as? String == "urltest")
        #expect(urltest?["interval"] as? String == "300s")
        #expect(urltest?["tolerance"] as? Int == 50)
    }

    @Test("resolveClashTarget 映射特殊目标")
    func targetMapping() {
        #expect(ClashRuleConverter.resolveClashTarget("DIRECT", knownGroups: []) == "direct-out")
        #expect(ClashRuleConverter.resolveClashTarget("REJECT", knownGroups: []) == "REJECT")
        #expect(ClashRuleConverter.resolveClashTarget("REJECT-DROP", knownGroups: []) == "REJECT")
        #expect(ClashRuleConverter.resolveClashTarget("PROXY", knownGroups: []) == "PROXY")
        #expect(ClashRuleConverter.resolveClashTarget("  ", knownGroups: []) == nil)
    }
}
