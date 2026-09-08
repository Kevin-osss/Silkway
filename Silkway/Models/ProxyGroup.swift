import Foundation

/// 策略组。
///
/// 对应 sing-box 的 selector / urltest 等出站类型，也对应 Clash 的 proxy-group。
/// 设计稿里菜单栏弹窗以策略组为主结构（广告拦截 / 人工智能 / 国内流量……），
/// 每组可展开显示其下节点。
struct ProxyGroup: Identifiable, Codable, Hashable, Sendable {

    let id: UUID

    /// 组名。同时是 sing-box 配置里该 outbound 的 tag，必须全局唯一。
    let name: String

    let type: GroupType

    /// 设计稿里每个组左侧有两字母角标（AD / AI / DV / CN……）。
    /// 不用 SF Symbol，因为组是用户自定义的，无法预先映射图标。
    let tag: String

    /// 组内成员。
    ///
    /// 存 tag 字符串而非 ProxyNode，因为策略组可以嵌套引用其他策略组
    /// （如「故障转移」组的成员是「美国策略」「香港策略」两个组）。
    /// 用 UUID 无法表达这种指向异构对象的引用，而 tag 是 sing-box 的原生标识。
    var memberTags: [String]

    /// 当前选中的成员 tag。urltest 类型下由内核自动决定，此处为最近一次的结果。
    var selectedTag: String?

    init(
        id: UUID = UUID(),
        name: String,
        type: GroupType,
        tag: String,
        memberTags: [String] = [],
        selectedTag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.tag = tag
        self.memberTags = memberTags
        self.selectedTag = selectedTag
    }
}

extension ProxyGroup {
    /// 用户是否可以手动切换该组的选中项。
    /// urltest / loadBalance 由内核自动决策，UI 上应禁用点选。
    var isUserSelectable: Bool {
        type == .selector || type == .fallback
    }
}

/// 策略组类型。
///
/// rawValue 对应 sing-box outbound 的 `type` 字段。注意 sing-box 用 `urltest`
/// （无连字符），而 Clash 用 `url-test` —— 订阅解析时需要做这层转换，
/// 不要把 Clash 的写法直接透传进配置。
enum GroupType: String, Codable, CaseIterable, Sendable {
    case selector
    case urltest
    case loadBalance = "loadbalance"
    case fallback

    /// 解析 Clash 订阅时用的别名映射。
    static func fromClashType(_ raw: String) -> GroupType? {
        switch raw.lowercased() {
        case "select", "selector":          return .selector
        case "url-test", "urltest":         return .urltest
        case "load-balance", "loadbalance": return .loadBalance
        case "fallback":                    return .fallback
        default:                            return nil
        }
    }

    var displayName: String {
        switch self {
        case .selector:    return "手动选择"
        case .urltest:     return "自动选择"
        case .loadBalance: return "负载均衡"
        case .fallback:    return "故障转移"
        }
    }
}

/// 代理模式。
///
/// rawValue 用英文标识符而非中文 —— 中文是展示文案，会随 i18n 变化，
/// 不能作为持久化的 key。手册 v1.0 示例里用了中文 rawValue，此处已修正。
enum ProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case global
    case rule
    case direct

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .global: return "全局"
        case .rule:   return "规则"
        case .direct: return "直连"
        }
    }
}
