import Foundation

/// 代理节点。
///
/// 设计约束：本类型**不含任何 UI 逻辑**。
/// 手册 v1.0 的示例里曾有 `latencyColor: Color` 计算属性，已移除，原因有二：
///   1. 会让 Models 层依赖 SwiftUI，破坏 SilkwayCore 的无头编译能力
///   2. 与手册 5.4「所有延迟显示必须走 LatencyBadge，禁止直接写颜色逻辑」直接冲突
/// 颜色映射统一由 Views/Components/LatencyBadge.swift 依据 `LatencyLevel` 决定。
struct ProxyNode: Identifiable, Codable, Hashable, Sendable {

    let id: UUID
    let name: String
    let server: String
    let port: Int

    /// 出站协议。用 enum 而非 String，避免拼写错误在运行期才暴露。
    let proxyProtocol: ProxyProtocol

    /// ISO 3166-1 alpha-2 国家码，如 "US" / "JP" / "HK"。
    /// 订阅里常常没有这个字段，需要从节点名称推断，所以是可选的。
    let countryCode: String?

    /// 延迟（毫秒）。nil 表示未测速或已超时 —— 这两种状态在 UI 上都显示为灰色，
    /// 但语义不同，因此额外用 `hasBeenTested` 区分。
    var latency: Int?

    /// 是否已经历过至少一次测速。用于区分「还没测」和「测了但超时」。
    var hasBeenTested: Bool = false

    /// 完整的 sing-box outbound 配置（JSON 字符串），由解析器生成。
    ///
    /// 只存 name/server/port 无法让 sing-box 真正连接 —— 每个协议还需要
    /// UUID/密码/传输层/TLS 等凭证。解析器在解析 URI 时顺手生成完整
    /// outbound 存这里，ConfigBuilder 直接取用。
    /// nil 表示该节点只解析出了元数据（如 Clash YAML 子集），生成配置时跳过。
    var outboundJSON: String?

    /// 来源订阅。nil 表示手动添加的节点。var 因为解析器产出的节点
    /// 在拉取流程里才确定归属哪个订阅。
    var subscriptionID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        server: String,
        port: Int,
        proxyProtocol: ProxyProtocol,
        countryCode: String? = nil,
        latency: Int? = nil,
        hasBeenTested: Bool = false,
        outboundJSON: String? = nil,
        subscriptionID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.server = server
        self.port = port
        self.proxyProtocol = proxyProtocol
        self.countryCode = countryCode
        self.latency = latency
        self.hasBeenTested = hasBeenTested
        self.outboundJSON = outboundJSON
        self.subscriptionID = subscriptionID
    }
}

// MARK: - 延迟分级

extension ProxyNode {

    /// 延迟等级。阈值委托给 LatencyLevel.resolve，不重复实现。
    var latencyLevel: LatencyLevel {
        .resolve(latency: latency, hasBeenTested: hasBeenTested)
    }

    /// 供 UI 直接显示的延迟文案。不含颜色，颜色由 LatencyBadge 决定。
    var displayLatency: String {
        switch latencyLevel {
        case .untested: return "—"
        case .timeout:  return "超时"
        case .good, .fair, .poor:
            // latency 在这三个分支必然非 nil，但不用 ! 强解包
            return latency.map { "\($0) ms" } ?? "—"
        }
    }
}

/// 延迟等级。阈值来自手册 5.4，全局唯一定义，任何地方都不得重复实现。
enum LatencyLevel: String, Codable, Sendable {
    case good      // < 200ms
    case fair      // 200–500ms
    case poor      // > 500ms
    case timeout   // 测过但失败
    case untested  // 尚未测速

    /// 唯一的阈值判定入口。ProxyNode 和 LatencyResult 都必须走这里，
    /// 防止阈值散落在多处后改不一致。
    static func resolve(latency: Int?, hasBeenTested: Bool) -> LatencyLevel {
        guard let latency else {
            return hasBeenTested ? .timeout : .untested
        }
        if latency < 200 { return .good }
        if latency <= 500 { return .fair }
        return .poor
    }
}

/// 测速结果。比裸 Int? 多一个「超时」态，与「未测速」区分。
enum LatencyResult: Sendable, Hashable {
    case untested
    case timeout
    case value(Int)   // 毫秒

    var level: LatencyLevel {
        switch self {
        case .untested:      return .untested
        case .timeout:       return .timeout
        case .value(let ms): return .resolve(latency: ms, hasBeenTested: true)
        }
    }
}

// MARK: - 协议类型

/// sing-box 支持的出站协议。
///
/// rawValue 直接对应 sing-box 配置里 outbound 的 `type` 字段，
/// 这样 ConfigBuilder 生成配置时无需再做一次映射。
enum ProxyProtocol: String, Codable, CaseIterable, Sendable {
    case shadowsocks
    case vmess
    case vless
    case trojan
    case hysteria2
    case tuic
    case wireguard
    case socks
    case http
    case ssh
    case direct

    /// UI 上显示的简短标签（对应设计稿的 ProtocolTag 组件）。
    var displayName: String {
        switch self {
        case .shadowsocks: return "SS"
        case .vmess:       return "VMess"
        case .vless:       return "VLESS"
        case .trojan:      return "Trojan"
        case .hysteria2:   return "Hysteria2"
        case .tuic:        return "TUIC"
        case .wireguard:   return "WireGuard"
        case .socks:       return "SOCKS"
        case .http:        return "HTTP"
        case .ssh:         return "SSH"
        case .direct:      return "直连"
        }
    }
}
