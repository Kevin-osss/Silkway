import Foundation

/// 完整导入的配置（含策略组与路由规则）。
///
/// 背景：节点订阅（分享链接 / SIP008 / sing-box 配置）只提供节点，由
/// ConfigBuilder 重新组装成统一 PROXY 结构；而 Clash YAML / sing-box 完整
/// 配置自带 proxy-groups 和 rules，用户期望保留原有的分流结构。
///
/// 设计上 ImportedProfile 是**惰性**的：
///   - 原始文本/JSON 原样保留（rawConfig），这样 sing-box 完整配置可以
///     零损耗直通（凭证字段我们本来就不完全理解，不该重写）；
///   - Clash YAML 在导入时转成 sing-box 结构存 outbounds/rules，
///     因为 sing-box 无法直接消费 Clash 语法；
///   - UI 从 rawConfig 提取组列表（用于菜单展示），从 outbounds/rules
///     生成最终配置。
struct ImportedProfile: Identifiable, Codable, Hashable, Sendable {

    let id: UUID

    /// 来源订阅。nil 表示手动导入（未来支持）。
    var subscriptionID: UUID?

    /// 用户可识别的名字（默认取订阅名或文件名）。
    var name: String

    /// sing-box 格式的 outbounds（selector/urltest 组 + 节点），
    /// 已按 sing-box schema 校验过的结构。Clash 源在导入时转换。
    var outbounds: [String]

    /// sing-box 格式的 route.rules JSON 字符串数组。
    var rules: [String]

    /// 原始配置原文（sing-box JSON 或转换后的中间态），
    /// 用于 UI 展示组列表等辅助用途。不进最终配置。
    var rawConfig: String?

    init(
        id: UUID = UUID(),
        subscriptionID: UUID? = nil,
        name: String,
        outbounds: [String],
        rules: [String],
        rawConfig: String? = nil
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.name = name
        self.outbounds = outbounds
        self.rules = rules
        self.rawConfig = rawConfig
    }
}

// MARK: - 策略组提取（用于菜单 UI）

extension ImportedProfile {

    /// 从 outbounds 提取策略组列表（type 为 selector/urltest/loadbalance/fallback）。
    /// 节点出站（type 为 shadowsocks/vmess 等）不在此列。
    var proxyGroups: [ProxyGroup] {
        outbounds.compactMap { raw in
            guard let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = dict["tag"] as? String,
                  let typeRaw = dict["type"] as? String,
                  let type = GroupType(rawValue: typeRaw)
            else { return nil }

            // 成员：selector/urltest 都有 outbounds 数组（子组 + 节点 tag）
            let members = (dict["outbounds"] as? [String]) ?? []
            return ProxyGroup(
                name: tag,
                type: type,
                tag: Self.badgeTag(for: tag),
                memberTags: members,
                selectedTag: nil  // 运行时从 sing-box API 获取
            )
        }
    }

    /// 组徽标：取组名前两个字符大写（与 SingBoxManager.badgeTag 同步）。
    private static func badgeTag(for name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased()
    }
}

// MARK: - 容错解码

extension ImportedProfile {
    /// 旧版本 JSON 缺少新字段时不至于解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            subscriptionID: try c.decodeIfPresent(UUID.self, forKey: .subscriptionID),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            outbounds: try c.decodeIfPresent([String].self, forKey: .outbounds) ?? [],
            rules: try c.decodeIfPresent([String].self, forKey: .rules) ?? [],
            rawConfig: try c.decodeIfPresent(String.self, forKey: .rawConfig)
        )
    }
}
