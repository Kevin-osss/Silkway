import Foundation

/// 从订阅原文构建 ImportedProfile 的正式入口。
///
/// 触发条件（满足其一即视为完整配置）：
///   - Clash YAML 且含 `proxy-groups:`（有策略组才值得保留，纯节点 YAML
///     走节点模式即可——我们生成的统一 PROXY 不逊于其裸节点列表）
///   - sing-box JSON 且 outbounds 里含 selector / urltest 出站
///
/// 返回 nil 表示该订阅不适合完整配置模式（调用方走节点模式）。
/// 不支持的规则/悬空引用等通过 skipped 带回，由订阅层合并进 UI 提示。
enum ProfileImporter {

    static func attemptImport(
        text: String,
        subscriptionID: UUID,
        name: String,
        existingProfileID: UUID? = nil
    ) -> (profile: ImportedProfile?, skipped: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("{") {
            return importSingBoxConfig(
                text: trimmed, subscriptionID: subscriptionID,
                name: name, existingProfileID: existingProfileID
            )
        }
        if trimmed.contains("proxy-groups:") {
            return importClashYAML(
                text: trimmed, subscriptionID: subscriptionID,
                name: name, existingProfileID: existingProfileID
            )
        }
        return (nil, [])
    }

    // MARK: - sing-box 完整配置

    /// sing-box 配置直通：outbounds（含策略组）原样保留，route.rules 原样保留。
    /// 我们不做字段重写——凭证与结构都是 sing-box 原生格式，重写只会丢信息。
    private static func importSingBoxConfig(
        text: String, subscriptionID: UUID, name: String, existingProfileID: UUID?
    ) -> (profile: ImportedProfile?, skipped: [String]) {
        guard let data = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = dict["outbounds"] as? [[String: Any]]
        else { return (nil, []) }

        // 结构型出站不参与代理选择，也不该被菜单当成策略组
        let structural: Set<String> = ["direct", "block", "dns"]
        let proxyOutbounds = outbounds.filter { dict in
            guard let type = dict["type"] as? String else { return false }
            return !structural.contains(type)
        }

        // 有策略组才值得走完整配置模式；纯节点配置用节点模式更简单
        let hasGroups = proxyOutbounds.contains { dict in
            ["selector", "urltest", "loadbalance", "fallback"].contains(dict["type"] as? String ?? "")
        }
        guard hasGroups else { return (nil, []) }

        let outboundStrings = proxyOutbounds.compactMap { dict -> String? in
            guard JSONSerialization.isValidJSONObject(dict),
                  let d = try? JSONSerialization.data(withJSONObject: dict)
            else { return nil }
            return String(data: d, encoding: .utf8)
        }

        let route = dict["route"] as? [String: Any]
        let rules = (route?["rules"] as? [[String: Any]] ?? []).compactMap { rule -> String? in
            guard JSONSerialization.isValidJSONObject(rule),
                  let d = try? JSONSerialization.data(withJSONObject: rule)
            else { return nil }
            return String(data: d, encoding: .utf8)
        }

        let profile = ImportedProfile(
            id: existingProfileID ?? UUID(),
            subscriptionID: subscriptionID,
            name: name,
            outbounds: outboundStrings,
            rules: rules,
            rawConfig: text
        )
        return (profile, [])
    }

    // MARK: - Clash YAML

    private static func importClashYAML(
        text: String, subscriptionID: UUID, name: String, existingProfileID: UUID?
    ) -> (profile: ImportedProfile?, skipped: [String]) {
        let nodes = ClashConverter.parseProxies(text)
        let groupDicts = ClashConverter.parseGroups(text)
        let ruleLines = ClashConverter.parseRules(text)

        let nodeNames = Set(nodes.compactMap { $0["name"] as? String })
        let groupNames = Set(groupDicts.compactMap { $0["name"] as? String })

        var outbounds: [[String: Any]] = []
        var skipped: [String] = []

        // 1. 节点出站
        for dict in nodes {
            guard let ob = ClashConverter.outbound(from: dict) else {
                skipped.append("\(dict["name"] as? String ?? "?")：凭证不全")
                continue
            }
            outbounds.append(ob)
        }

        // 2. 组出站。任何悬空引用（指向不存在的节点/组）都让整个组跳过——
        //    sing-box 对不存在的 tag 直接启动失败，留着等于埋雷。
        for dict in groupDicts {
            let gname = dict["name"] as? String ?? "?"
            let rawMembers = (dict["proxies"] as? [String]) ?? []

            var members: [String] = []
            var hasDangling = false
            for raw in rawMembers {
                guard let tag = ClashRuleConverter.resolveClashTarget(raw, knownGroups: groupNames) else {
                    hasDangling = true
                    continue
                }
                let isSpecial = ["direct-out", "REJECT"].contains(tag)
                if !isSpecial, !nodeNames.contains(tag), !groupNames.contains(tag) {
                    hasDangling = true
                    continue
                }
                members.append(tag)
            }

            if hasDangling {
                skipped.append("\(gname)：含悬空引用（成员不存在），该组已跳过")
                continue
            }
            guard let ob = ClashRuleConverter.groupOutbound(from: dict, members: members) else {
                skipped.append("\(gname)：组配置无法转换")
                continue
            }
            outbounds.append(ob)
        }

        // 3. 规则转换
        let converted = ClashRuleConverter.convertAll(ruleLines) { raw in
            let target = raw.trimmingCharacters(in: .whitespaces)
            if target.uppercased() == "DIRECT" { return "direct-out" }
            if ["REJECT", "REJECT-DROP"].contains(target.uppercased()) { return "REJECT" }
            return (nodeNames.contains(target) || groupNames.contains(target)) ? target : nil
        }
        skipped.append(contentsOf: converted.skipped)

        // 完全没有组也没有规则，就没有保留完整配置的价值
        guard !groupDicts.isEmpty || !ruleLines.isEmpty else { return (nil, []) }

        let profile = ImportedProfile(
            id: existingProfileID ?? UUID(),
            subscriptionID: subscriptionID,
            name: name,
            outbounds: outbounds.compactMap(serialize),
            rules: converted.rules.compactMap(serialize),
            rawConfig: text
        )
        return (profile, skipped)
    }

    private static func serialize(_ dict: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
