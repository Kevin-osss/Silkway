import Foundation
import Testing
@testable import SilkwayCore

/// 完整配置导入的端到端测试。
///
/// 链路：Clash YAML（含 proxy-groups + rules）→ ImportedProfile →
/// ConfigBuilder 完整模式 → 真实 sing-box check。
///
/// sing-box check 只能验证 schema 合法性，不能保证分流语义正确。
/// 语义正确性靠规则转换器的单元测试（ClashRuleConverterTests）钉死。
@Suite("完整配置导入")
struct ImportedProfileTests {

    /// 一份覆盖常见结构的 Clash YAML 样本
    private let clashYAML = """
    proxies:
      - {name: 香港01, type: ss, server: hk01.example.com, port: 8388, cipher: aes-256-gcm, password: hk-pw}
      - {name: 美国01, type: trojan, server: us01.example.com, port: 443, password: us-pw, sni: us01.example.com}
    proxy-groups:
      - name: PROXY
        type: select
        proxies:
          - 香港01
          - 美国01
      - name: 自动选择
        type: url-test
        url: http://cp.cloudflare.com/generate_204
        interval: 300
        proxies:
          - 香港01
          - 美国01
    rules:
      - DOMAIN-SUFFIX,baidu.com,DIRECT
      - DOMAIN-KEYWORD,google,PROXY
      - IP-CIDR,91.108.56.0/22,PROXY,no-resolve
      - GEOIP,CN,DIRECT
      - MATCH,PROXY
    """

    private let subID = UUID()

    @Test("正式 API：Clash YAML 产出 profile")
    func importerClashYAML() throws {
        let (profile, skipped) = ProfileImporter.attemptImport(
            text: clashYAML, subscriptionID: subID, name: "测试机场"
        )
        let p = try #require(profile)
        #expect(p.subscriptionID == subID)
        #expect(p.name == "测试机场")
        #expect(p.outbounds.count == 4)
        #expect(p.rules.count == 4)
        #expect(skipped.isEmpty)
    }

    @Test("正式 API：纯节点 YAML 返回 nil 走节点模式")
    func importerNodeOnlyYAML() throws {
        let yaml = """
        proxies:
          - {name: A, type: ss, server: a.com, port: 8388, cipher: aes-256-gcm, password: pw}
        """
        let (profile, skipped) = ProfileImporter.attemptImport(
            text: yaml, subscriptionID: subID, name: "x"
        )
        #expect(profile == nil)
        #expect(skipped.isEmpty)
    }

    @Test("正式 API：sing-box 配置含 selector 时直通保留")
    func importerSingBoxConfig() throws {
        let json = """
        {
          "log": {"level": "error"},
          "outbounds": [
            {"type": "selector", "tag": "PROXY", "outbounds": ["n1", "n2"], "default": "n1"},
            {"type": "shadowsocks", "tag": "n1", "server": "a.com", "server_port": 8388, "method": "aes-256-gcm", "password": "pw"},
            {"type": "vmess", "tag": "n2", "server": "b.com", "server_port": 443, "uuid": "11111111-2222-3333-4444-555555555555"},
            {"type": "direct", "tag": "direct-out"},
            {"type": "dns", "tag": "dns-out"}
          ],
          "route": {
            "rules": [
              {"domain_suffix": ["cn"], "outbound": "direct-out"},
              {"ip_is_private": true, "outbound": "direct-out"}
            ],
            "final": "PROXY"
          }
        }
        """
        let (profile, _) = ProfileImporter.attemptImport(
            text: json, subscriptionID: subID, name: "sing-box 订阅"
        )
        let p = try #require(profile)
        // direct/dns 出站被过滤，只剩 1 组 + 2 节点
        #expect(p.outbounds.count == 3)
        #expect(p.rules.count == 2, "route.rules 应原样保留")
        #expect(p.rawConfig != nil)
    }

    @Test("正式 API：sing-box 纯节点配置返回 nil")
    func importerSingBoxNodesOnly() throws {
        let json = #"{"outbounds": [{"type": "shadowsocks", "tag": "n1", "server": "a.com", "server_port": 8388, "method": "aes-256-gcm", "password": "pw"}]}"#
        let (profile, _) = ProfileImporter.attemptImport(
            text: json, subscriptionID: subID, name: "x"
        )
        #expect(profile == nil)
    }

    @Test("重复导入复用同一 profile id")
    func importerReusesExistingID() throws {
        let existingID = UUID()
        let (p1, _) = ProfileImporter.attemptImport(
            text: clashYAML, subscriptionID: subID, name: "x", existingProfileID: existingID
        )
        #expect(p1?.id == existingID)
    }

    // MARK: - ImportedProfile 提取

    @Test("从 sing-box 完整配置提取策略组")
    func extractGroupsFromSingBoxJSON() throws {
        let json = """
        {
          "outbounds": [
            {"type": "selector", "tag": "PROXY", "outbounds": ["n1", "n2"], "default": "n1"},
            {"type": "urltest", "tag": "自动", "outbounds": ["n1"], "url": "http://x/204", "interval": "300s"},
            {"type": "shadowsocks", "tag": "n1", "server": "a.com", "server_port": 8388, "method": "aes-256-gcm", "password": "pw"},
            {"type": "direct", "tag": "direct-out"}
          ]
        }
        """
        let profile = ImportedProfile(
            name: "测试",
            outbounds: [
                #"{"type":"selector","tag":"PROXY","outbounds":["n1","n2"],"default":"n1"}"#,
                #"{"type":"urltest","tag":"自动","outbounds":["n1"]}"#,
                #"{"type":"shadowsocks","tag":"n1","server":"a.com","server_port":8388,"method":"aes-256-gcm","password":"pw"}"#,
            ],
            rules: []
        )

        let groups = profile.proxyGroups
        #expect(groups.count == 2, "只应提取 selector/urltest，节点不算组")
        #expect(groups.first?.name == "PROXY")
        #expect(groups.first?.memberTags == ["n1", "n2"])
        #expect(groups.last?.name == "自动")
        #expect(groups.last?.type == .urltest)
    }

    // MARK: - Clash YAML → ImportedProfile（转换器组装）

    /// 把 Clash YAML 转成 ImportedProfile 的完整流程。
    /// 这个函数在 SubscriptionManager 更新订阅时调用。
    private func clashToProfile(_ yaml: String, name: String = "测试配置") -> (ImportedProfile?, [String]) {
        let nodes = ClashConverter.parseProxies(yaml)
        let groupDicts = ClashConverter.parseGroups(yaml)
        let ruleLines = ClashConverter.parseRules(yaml)

        // 节点名集合（组引用节点时校验）
        let nodeNames = Set(nodes.compactMap { $0["name"] as? String })
        let groupNames = Set(groupDicts.compactMap { $0["name"] as? String })

        // 1. 节点出站
        var outbounds: [[String: Any]] = []
        var skipped: [String] = []
        for dict in nodes {
            guard let ob = ClashConverter.outbound(from: dict) else {
                skipped.append("\(dict["name"] ?? "?")：凭证不全")
                continue
            }
            outbounds.append(ob)
        }

        // 2. 组出站：成员引用可以是节点、其他组、DIRECT/REJECT。
        //    任何悬空引用（指向不存在的节点/组）都会让整个组被跳过——
        //    sing-box 对不存在的 tag 直接启动失败，留着它等于埋雷。
        for dict in groupDicts {
            let name = dict["name"] as? String ?? "?"
            let rawMembers = (dict["proxies"] as? [String]) ?? []

            var members: [String] = []
            var hasDangling = false
            for raw in rawMembers {
                guard let tag = ClashRuleConverter.resolveClashTarget(raw, knownGroups: groupNames) else {
                    hasDangling = true
                    continue
                }
                // DIRECT/REJECT 特殊目标恒合法；其余引用必须真实存在
                let isSpecial = ["direct-out", "REJECT"].contains(tag)
                if !isSpecial, !nodeNames.contains(tag), !groupNames.contains(tag) {
                    hasDangling = true
                    continue
                }
                members.append(tag)
            }

            if hasDangling {
                skipped.append("\(name)：含悬空引用（成员不存在），该组已跳过")
                continue
            }
            guard let ob = ClashRuleConverter.groupOutbound(from: dict, members: members) else {
                skipped.append("\(name)：组配置无法转换")
                continue
            }
            outbounds.append(ob)
        }

        // 3. 规则转换
        let converted = ClashRuleConverter.convertAll(ruleLines) { raw in
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.uppercased() == "DIRECT" { return "direct-out" }
            if name.uppercased() == "REJECT" || name.uppercased() == "REJECT-DROP" { return "REJECT" }
            // 节点或组都按 tag 透传；都不存在则返回 nil（悬空引用）
            return (nodeNames.contains(name) || groupNames.contains(name)) ? name : nil
        }

        // 悬空引用检测：resolveTarget 返回 nil 的成员名
        for dict in groupDicts {
            let gname = dict["name"] as? String ?? "?"
            for raw in (dict["proxies"] as? [String]) ?? [] {
                let name = raw.trimmingCharacters(in: .whitespaces)
                let isSpecial = ["DIRECT", "REJECT", "REJECT-DROP"].contains(name.uppercased())
                if !isSpecial, !nodeNames.contains(name), !groupNames.contains(name) {
                    skipped.append("\(gname)：引用了不存在的成员「\(name)」，该组已跳过")
                }
            }
        }
        skipped.append(contentsOf: converted.skipped)

        let profile = ImportedProfile(
            name: name,
            outbounds: outbounds.compactMap { dict -> String? in
                guard JSONSerialization.isValidJSONObject(dict),
                      let d = try? JSONSerialization.data(withJSONObject: dict)
                else { return nil }
                return String(data: d, encoding: .utf8)
            },
            rules: converted.rules.compactMap { dict -> String? in
                guard JSONSerialization.isValidJSONObject(dict),
                      let d = try? JSONSerialization.data(withJSONObject: dict)
                else { return nil }
                return String(data: d, encoding: .utf8)
            },
            rawConfig: yaml
        )
        return (profile, skipped)
    }

    @Test("Clash 完整 YAML 生成可用配置并过 sing-box check")
    func clashFullYAMLPassesCheck() throws {
        let (profile, skipped) = clashToProfile(clashYAML)
        let p = try #require(profile)

        #expect(p.outbounds.count == 4, "2 节点 + 2 组，实际 \(p.outbounds.count)")
        #expect(p.rules.count == 4, "MATCH 进 final，其余 4 条进 rules，实际 \(p.rules.count)")
        #expect(skipped.isEmpty, "不应有跳过项，实际: \(skipped)")

        let config = try ConfigBuilder.data(
            nodes: [], config: AppConfig(),
            apiPort: 19101, mixedPort: 17901,
            profile: p
        )
        try runSingBoxCheck(config)

        // 断言最终配置的结构
        let dict = try #require(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let outbounds = try #require(dict["outbounds"] as? [[String: Any]])
        let tags = outbounds.compactMap { $0["tag"] as? String }
        #expect(tags.contains("PROXY"), "应保留 Clash 的策略组")
        #expect(tags.contains("自动选择"))
        #expect(tags.contains("direct-out"), "应自动注入 direct-out")
        #expect(tags.contains("REJECT"), "应自动注入 REJECT block 出站")

        let route = try #require(dict["route"] as? [String: Any])
        #expect(route["final"] as? String == "PROXY", "MATCH,PROXY 应成为 final")
        let rules = try #require(route["rules"] as? [[String: Any]])
        #expect(rules.contains { $0["domain_suffix"] as? [String] == ["baidu.com"] })
        #expect(rules.contains { $0["rule_set"] as? [String] == ["geoip-cn"] })
    }

    @Test("全局/直连模式覆盖 final")
    func modeOverridesFinal() throws {
        let (profile, _) = clashToProfile(clashYAML)
        let p = try #require(profile)

        var globalConfig = AppConfig()
        globalConfig.mode = .global
        let data1 = try ConfigBuilder.data(
            nodes: [], config: globalConfig,
            apiPort: 19102, mixedPort: 17902, profile: p
        )
        let d1 = try #require(try JSONSerialization.jsonObject(with: data1) as? [String: Any])
        let r1 = try #require(d1["route"] as? [String: Any])
        #expect(r1["final"] as? String == "PROXY", "全局模式应走第一个策略组")

        var directConfig = AppConfig()
        directConfig.mode = .direct
        let data2 = try ConfigBuilder.data(
            nodes: [], config: directConfig,
            apiPort: 19103, mixedPort: 17903, profile: p
        )
        let d2 = try #require(try JSONSerialization.jsonObject(with: data2) as? [String: Any])
        let r2 = try #require(d2["route"] as? [String: Any])
        #expect(r2["final"] as? String == "direct-out")
    }

    @Test("引用了不存在成员的组被跳过并报告")
    func danglingGroupReference() throws {
        let yaml = """
        proxies:
          - {name: 香港01, type: ss, server: hk.example.com, port: 8388, cipher: aes-256-gcm, password: pw}
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - 香港01
              - 不存在的节点
        """
        let (profile, skipped) = clashToProfile(yaml)
        let p = try #require(profile)
        // 组因悬空引用被整体跳过，只剩节点出站
        #expect(!p.outbounds.contains { $0.contains("\"tag\":\"PROXY\"") })
        #expect(skipped.contains { $0.contains("不存在的节点") })
    }

    // MARK: - 工具

    private func runSingBoxCheck(_ config: Data) throws {
        let binaryPath = "\(FileManager.default.currentDirectoryPath)/spike/sing-box"
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configURL = tmpDir.appendingPathComponent("config.json")
        try config.write(to: configURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["check", "-c", configURL.path, "-D", tmpDir.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        if process.terminationReason != .exit || process.terminationStatus != 0 {
            let errText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            Issue.record("sing-box check 失败 (exit=\(process.terminationStatus)):\n\(errText)")
        }
    }
}
