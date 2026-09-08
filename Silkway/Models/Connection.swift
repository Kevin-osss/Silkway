import Foundation

/// 一条活跃连接。对应 Clash API `GET /connections` 返回的单项。
///
/// 这是**只读的运行时数据**，来自内核，不持久化，因此不需要自定义 id ——
/// 用内核给的 id 即可。
struct Connection: Identifiable, Codable, Hashable, Sendable {

    /// 内核分配的连接 id，用于 `DELETE /connections/{id}` 断开指定连接。
    let id: String

    let host: String
    let destinationPort: Int

    /// "TCP" / "UDP"。内核返回的是 network 字段。
    let network: String

    /// 命中的规则，如 "DOMAIN-SUFFIX" / "GEOIP" / "RULE-SET"。
    let rule: String

    /// 规则的具体载荷，如 "github.com"。设计稿要求连接日志高亮显示命中的规则名。
    let rulePayload: String?

    /// 该连接经过的出站链路，如 ["PROXY", "香港 IEPL 01"]。
    let chains: [String]

    let uploadBytes: Int64
    let downloadBytes: Int64

    let startTime: Date
}

extension Connection {

    /// 连接已持续的时长。
    func duration(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(startTime)
    }

    /// 出站链路的末端 —— 也就是实际使用的节点名。
    ///
    /// Clash API 的 chains 是**倒序**的（[最终出站, ..., 入口]），
    /// 所以实际节点是第一个元素而非最后一个。这点极易搞反。
    var actualOutbound: String? { chains.first }

    var totalBytes: Int64 { uploadBytes + downloadBytes }
}
