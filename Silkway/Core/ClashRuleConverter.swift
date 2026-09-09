import Foundation

/// Clash 规则语法 → sing-box 1.13 `route.rules` 的转换器。
///
/// 这是完整配置导入里风险最高的一步：Clash 的规则是字符串行
/// （`DOMAIN-SUFFIX,google.com,PROXY`），sing-box 是结构化 JSON。
/// 转换错了不会报错——配置能过 sing-box check，但分流结果全错，
/// 且这种错误用户很难察觉。所以每条规则的转换都必须有测试钉死。
///
/// 不支持的规则类型**显式跳过并记录原因**，绝不静默丢弃——
/// 静默丢弃会让用户以为规则生效了，实际上流量根本没走预期的出口。
enum ClashRuleConverter {

    /// 单条规则的转换结果。
    enum Outcome {
        case rule([String: Any])
        case finalTarget(String)
        /// 转换失败，附原因（写入订阅的 skippedReasons 供 UI 展示）
        case skipped(String)
    }

    /// 转换一条 Clash 规则。
    ///
    /// - Parameters:
    ///   - line: 规则原文，如 `DOMAIN-SUFFIX,google.com,PROXY,no-resolve`
    ///   - resolveGroup: 把 Clash 的组名/特殊目标解析成 sing-box outbound tag。
    ///     返回 nil 表示该目标无法映射（如引用了不存在的组），规则应跳过。
    /// - Returns: 转换结果，失败时带原因。
    static func convert(
        _ line: String,
        resolveTarget: (String) -> String?
    ) -> Outcome {
        let parts = line.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let type = parts.first, !type.isEmpty else {
            return .skipped("规则为空")
        }

        switch type {
        case "MATCH":
            // MATCH 是兜底，等价于 sing-box 的 route.final。
            // 返回特殊标记，由调用方决定是写 final 还是当普通规则。
            guard let target = parts.count > 1 ? resolveTarget(parts[1]) : nil else {
                return .skipped("MATCH 目标无法解析")
            }
            return .finalTarget(target)

        case "DOMAIN-SUFFIX":
            return domainRule(parts, resolveTarget: resolveTarget) { ["domain_suffix": [$0]] }

        case "DOMAIN":
            return domainRule(parts, resolveTarget: resolveTarget) { ["domain": [$0]] }

        case "DOMAIN-KEYWORD":
            return domainRule(parts, resolveTarget: resolveTarget) { ["domain_keyword": [$0]] }

        case "IP-CIDR", "IP-CIDR6":
            // no-resolve 是 Clash 的优化提示（匹配 IP 规则前不解析域名），
            // sing-box 的 ip_cidr 天然只匹配已解析的 IP，语义一致，忽略该选项
            guard parts.count >= 3 else { return .skipped("\(type) 规则缺少参数") }
            guard let target = resolveTarget(parts[2]) else {
                return .skipped("IP-CIDR 目标 \(parts[2]) 无法解析")
            }
            return .rule([
                "ip_cidr": [parts[1]],
                "action": "route",
                "outbound": target,
            ])

        case "SRC-IP-CIDR":
            guard parts.count >= 3 else { return .skipped("SRC-IP-CIDR 规则缺少参数") }
            guard let target = resolveTarget(parts[2]) else {
                return .skipped("SRC-IP-CIDR 目标 \(parts[2]) 无法解析")
            }
            return .rule([
                "source_ip_cidr": [parts[1]],
                "action": "route",
                "outbound": target,
            ])

        case "DST-PORT":
            guard parts.count >= 3, let port = Int(parts[1]) else {
                return .skipped("DST-PORT 规则格式有误")
            }
            guard let target = resolveTarget(parts[2]) else {
                return .skipped("DST-PORT 目标 \(parts[2]) 无法解析")
            }
            return .rule([
                "port": [port],
                "action": "route",
                "outbound": target,
            ])

        case "GEOIP":
            // sing-box 1.12 移除了内建 geoip 字段，必须走 rule_set。
            // 我们能直接服务的只有 geoip-cn（RuleSetManager 已下载的本地规则集）；
            // 其他国家的规则集文件本地没有，转成 rule_set 引用会让 sing-box
            // 启动直接失败，不如在这里明确跳过。
            guard parts.count >= 3 else { return .skipped("GEOIP 规则缺少参数") }
            guard parts[1].lowercased() == "cn" else {
                return .skipped("GEOIP,\(parts[1]) 需要本地未下载的规则集")
            }
            guard let target = resolveTarget(parts[2]) else {
                return .skipped("GEOIP 目标 \(parts[2]) 无法解析")
            }
            return .rule([
                "rule_set": ["geoip-cn"],
                "action": "route",
                "outbound": target,
            ])

        case "GEOSITE":
            // 同 GEOIP：只有 geosite-cn 本地现成
            guard parts.count >= 3 else { return .skipped("GEOSITE 规则缺少参数") }
            guard parts[1].lowercased() == "cn" else {
                return .skipped("GEOSITE,\(parts[1]) 需要本地未下载的规则集")
            }
            guard let target = resolveTarget(parts[2]) else {
                return .skipped("GEOSITE 目标 \(parts[2]) 无法解析")
            }
            return .rule([
                "rule_set": ["geosite-cn"],
                "action": "route",
                "outbound": target,
            ])

        default:
            return .skipped("\(type) 规则类型不支持")
        }
    }

    /// 域名类规则的公共骨架：第 2 段是值，第 3 段是目标。
    private static func domainRule(
        _ parts: [String],
        resolveTarget: (String) -> String?,
        makeField: (String) -> [String: Any]
    ) -> Outcome {
        guard parts.count >= 3 else { return .skipped("\(parts[0]) 规则缺少参数") }
        guard let target = resolveTarget(parts[2]) else {
            return .skipped("\(parts[0]) 目标 \(parts[2]) 无法解析")
        }
        var rule = makeField(parts[1])
        rule["action"] = "route"
        rule["outbound"] = target
        return .rule(rule)
    }

    /// 把一组规则行转成 sing-box rules + final + 跳过明细。
    ///
    /// MATCH 规则不进入 rules 数组——sing-box 用 route.final 表达兜底，
    /// 多条 MATCH 没有意义，取最后一条。
    static func convertAll(
        _ lines: [String],
        resolveTarget: (String) -> String?
    ) -> (rules: [[String: Any]], final: String?, skipped: [String]) {
        var rules: [[String: Any]] = []
        var final: String?
        var skipped: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            switch convert(trimmed, resolveTarget: resolveTarget) {
            case .rule(let rule):
                rules.append(rule)
            case .finalTarget(let target):
                final = target
            case .skipped(let reason):
                skipped.append("\(trimmed)：\(reason)")
            }
        }

        return (rules, final, skipped)
    }
}

// MARK: - proxy-groups 转换

extension ClashRuleConverter {

    /// Clash proxy-group 字典 → sing-box selector / urltest outbound。
    ///
    /// - Parameters:
    ///   - dict: proxy-groups 的一项（已含嵌套结构）
    ///   - memberTags: 解析后的成员 tag 列表（子组 tag / 节点 tag / "direct-out" / "REJECT"）
    static func groupOutbound(from dict: [String: Any], members: [String]) -> [String: Any]? {
        guard let name = dict["name"] as? String, !name.isEmpty,
              let typeRaw = dict["type"] as? String,
              let type = GroupType.fromClashType(typeRaw)
        else { return nil }

        guard !members.isEmpty else { return nil }

        var outbound: [String: Any] = [
            "type": type.rawValue,
            "tag": name,
            "outbounds": members,
        ]

        // urltest / loadbalance 需要测试目标与间隔
        if type == .urltest || type == .loadBalance {
            let url = dict["url"] as? String
            outbound["url"] = (url?.isEmpty == false) ? url : "http://www.gstatic.com/generate_204"
            if let interval = dict["interval"] as? String, let seconds = Int(interval) {
                outbound["interval"] = "\(seconds)s"
            } else if let interval = dict["interval"] as? Int {
                outbound["interval"] = "\(interval)s"
            } else {
                outbound["interval"] = "300s"
            }
            if let tolerance = dict["tolerance"] as? String, let t = Int(tolerance) {
                outbound["tolerance"] = t
            }
        }

        return outbound
    }

    /// 把 Clash 组名/特殊目标解析为 sing-box 可识别的 tag。
    ///
    /// Clash 的 DIRECT/REJECT 是特殊目标：
    ///   DIRECT → direct-out（ConfigBuilder 保证存在）
    ///   REJECT → REJECT（ConfigBuilder 注入 block 出站）
    /// 组名与节点名原样透传（sing-box tag 就是它们）。
    static func resolveClashTarget(_ raw: String, knownGroups: Set<String>) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        switch name.uppercased() {
        case "DIRECT":
            return "direct-out"
        case "REJECT", "REJECT-DROP":
            return "REJECT"
        default:
            return name.isEmpty ? nil : name
        }
    }
}
