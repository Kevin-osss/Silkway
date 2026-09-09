import Foundation

/// 把订阅文本解析为 ProxyNode 数组。
///
/// 支持格式：
///   1. 多行 URI（Base64 编码或明文），每行一个 vmess/vless/trojan/ss/hysteria2
///   2. SIP008 JSON（outbounds 数组）
///   3. Clash YAML 的 `proxies:` 列表（仅解析常见字段子集）
enum SubscriptionParser {

    /// 解析失败时返回空数组，不抛异常 —— 由调用方检查 nodeCount。
    /// 解析结果：除了节点，还带回被丢弃的条目。
    ///
    /// 为什么需要这个：机场订阅里混着我们不支持的协议（ssr/snell）或缺凭证的条目，
    /// 静默丢弃会让用户面对「机场说有 80 个节点，这里只有 52 个」而无从判断是
    /// 自己的错还是机场的错。
    struct ParseResult: Sendable {
        var nodes: [ProxyNode]
        /// 被丢弃条目的描述，形如 "香港01：ssr 协议不支持"
        var skipped: [String]

        var skippedCount: Int { skipped.count }
    }

    /// 兼容入口：只要节点。
    static func parse(_ text: String) -> [ProxyNode] {
        parseDetailed(text).nodes
    }

    /// 完整入口：节点 + 丢弃明细。
    static func parseDetailed(_ text: String) -> ParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParseResult(nodes: [], skipped: []) }

        // 1. 尝试 SIP008 / sing-box 完整配置 JSON
        if trimmed.hasPrefix("{"), let result = parseJSONDetailed(trimmed) {
            return result
        }

        // 2. 尝试 Clash YAML
        if trimmed.contains("proxies:") || trimmed.contains("Proxy:") {
            if let result = parseClashDetailed(trimmed) {
                return result
            }
        }

        // 3. 按行解析 URI
        let lines = trimmed.components(separatedBy: .newlines)
        let decoded = lines.flatMap { decodeLine($0) }
        if !decoded.isEmpty {
            return ParseResult(nodes: decoded, skipped: skippedURILines(lines))
        }

        // 4. 整段文本可能是 Base64 编码的多行 URI
        if let whole = decodeBase64(trimmed) {
            let innerLines = whole.components(separatedBy: .newlines)
            let nodes = innerLines.flatMap { decodeLine($0) }
            return ParseResult(nodes: nodes, skipped: skippedURILines(innerLines))
        }

        return ParseResult(nodes: [], skipped: [])
    }

    /// 找出长得像分享链接、但没能解析成节点的行。
    private static func skippedURILines(_ lines: [String]) -> [String] {
        lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("://"), decodeLine(line).isEmpty else { return nil }
            let scheme = line.components(separatedBy: "://").first ?? "未知"
            return "\(scheme) 协议不支持或链接格式有误"
        }
    }

    // MARK: - 单行 URI 解码

    /// 处理单行：去空、可能是 Base64 包着的 URI、或者直接就是 URI。
    private static func decodeLine(_ raw: String) -> [ProxyNode] {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }

        // 有些机场把整段 URI 再包一层 Base64
        if let decoded = decodeBase64(line), decoded != line {
            return decoded.components(separatedBy: .newlines).flatMap { parseURI($0) }
        }

        return parseURI(line)
    }

    /// 解析单条 URI。
    private static func parseURI(_ uri: String) -> [ProxyNode] {
        guard let url = URL(string: uri) else { return [] }
        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "vmess":
            return [parseVMess(uri)].compactMap { $0 }
        case "vless":
            return [parseVLESS(url)].compactMap { $0 }
        case "trojan":
            return [parseTrojan(url)].compactMap { $0 }
        case "ss":
            return parseSS(uri).compactMap { $0 }
        case "hysteria2", "h2", "hy2":
            return [parseHysteria2(url)].compactMap { $0 }
        case "tuic":
            return [parseTUIC(url)].compactMap { $0 }
        case "anytls":
            return [parseAnyTLS(url)].compactMap { $0 }
        default:
            return []
        }
    }

    // MARK: - tuic:// 与 anytls://

    /// tuic://uuid:password@host:port?params#name
    private static func parseTUIC(_ url: URL) -> ProxyNode? {
        guard let host = url.host, let port = url.port,
              let uuid = url.user, !uuid.isEmpty
        else { return nil }
        let name = url.fragment?.removingPercentEncoding ?? "TUIC"
        let query = queryItems(url)

        var node = ProxyNode(
            name: name,
            server: host,
            port: port,
            proxyProtocol: .tuic,
            countryCode: inferCountry(from: name)
        )
        var base: [String: Any] = [
            "type": "tuic",
            "server": host,
            "server_port": port,
            "uuid": uuid,
        ]
        if let password = url.password, !password.isEmpty { base["password"] = password }
        if let cc = query["congestion_control"] ?? query["congestion-controller"], !cc.isEmpty {
            base["congestion_control"] = cc
        }
        if let mode = query["udp_relay_mode"], !mode.isEmpty { base["udp_relay_mode"] = mode }

        // tuic 建在 QUIC 上，TLS 必开
        var tls: [String: Any] = ["enabled": true]
        if let sni = query["sni"], !sni.isEmpty { tls["server_name"] = sni }
        if query["allow_insecure"] == "1" || query["insecure"] == "1" { tls["insecure"] = true }
        if let alpn = query["alpn"], !alpn.isEmpty {
            tls["alpn"] = alpn.split(separator: ",").map { String($0) }
        }
        node.outboundJSON = makeOutboundJSON(base, tls: tls)
        return node
    }

    /// anytls://password@host:port?params#name
    private static func parseAnyTLS(_ url: URL) -> ProxyNode? {
        guard let host = url.host, let port = url.port,
              let password = url.password ?? url.user, !password.isEmpty
        else { return nil }
        let name = url.fragment?.removingPercentEncoding ?? "AnyTLS"
        let query = queryItems(url)

        var node = ProxyNode(
            name: name,
            server: host,
            port: port,
            proxyProtocol: .anytls,
            countryCode: inferCountry(from: name)
        )
        var tls: [String: Any] = ["enabled": true]
        if let sni = query["sni"], !sni.isEmpty { tls["server_name"] = sni }
        if query["insecure"] == "1" { tls["insecure"] = true }
        node.outboundJSON = makeOutboundJSON(
            [
                "type": "anytls",
                "server": host,
                "server_port": port,
                "password": password,
            ],
            tls: tls
        )
        return node
    }

    // MARK: - vmess://BASE64

    private static func parseVMess(_ uri: String) -> ProxyNode? {
        // vmess://BASE64JSON
        let prefix = "vmess://"
        guard uri.hasPrefix(prefix) else { return nil }
        let b64 = String(uri.dropFirst(prefix.count))
        guard let jsonData = Data(base64Encoded: paddedBase64(b64)),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return nil }

        let name = (json["ps"] as? String) ?? "VMess"
        guard let server = json["add"] as? String,
              let port = parsePort(json["port"]),
              let uuid = json["id"] as? String
        else { return nil }

        var node = ProxyNode(
            name: name,
            server: server,
            port: port,
            proxyProtocol: .vmess,
            countryCode: inferCountry(from: name)
        )
        node.outboundJSON = makeOutboundJSON([
            "type": "vmess",
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "security": (json["scy"] as? String) ?? "auto",
            "alter_id": parseInt(json["aid"]) ?? 0,
        ], tls: tlsFrom(json: json), transport: transportFrom(json: json))
        return node
    }

    // MARK: - sing-box outbound 组装

    /// 把 outbound 基本字段 + tls + transport 合并为 sing-box 要求的嵌套结构，并序列化。
    private static func makeOutboundJSON(
        _ base: [String: Any],
        tls: [String: Any]? = nil,
        transport: [String: Any]? = nil
    ) -> String? {
        var outbound = base
        if let tls { outbound["tls"] = tls }
        if let transport { outbound["transport"] = transport }
        guard JSONSerialization.isValidJSONObject(outbound),
              let data = try? JSONSerialization.data(withJSONObject: outbound)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// vmess JSON 中的 TLS 字段 → sing-box tls outbound。
    /// vmess JSON 的 tls 字段为 "tls" 表示开启，sni 字段指定 SNI。
    private static func tlsFrom(json: [String: Any]) -> [String: Any]? {
        guard (json["tls"] as? String)?.lowercased() == "tls" else { return nil }
        var tls: [String: Any] = ["enabled": true]
        if let sni = json["sni"] as? String, !sni.isEmpty { tls["server_name"] = sni }
        if let alpn = json["alpn"] as? String, !alpn.isEmpty {
            tls["alpn"] = alpn.split(separator: ",").map { String($0) }
        }
        return tls
    }

    /// vmess JSON 中的网络字段 → sing-box transport。
    /// net: tcp / ws / grpc / h2；host/path 随网络类型含义不同。
    private static func transportFrom(json: [String: Any]) -> [String: Any]? {
        let network = (json["net"] as? String)?.lowercased() ?? "tcp"
        let host = json["host"] as? String ?? ""
        let path = json["path"] as? String ?? ""
        switch network {
        case "ws":
            var ws: [String: Any] = ["type": "ws", "path": path.isEmpty ? "/" : path]
            if !host.isEmpty { ws["headers"] = ["Host": host] }
            return ws
        case "grpc":
            // vmess 的 path 字段在 grpc 下即 service name
            return ["type": "grpc", "service_name": path.isEmpty ? "gun" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        case "h2":
            var h2: [String: Any] = ["type": "http"]
            if !host.isEmpty { h2["host"] = [host] }
            if !path.isEmpty { h2["path"] = path }
            return h2
        default:
            return nil // tcp 无需 transport 字段
        }
    }

    /// URL query 参数便捷取用（已 percent-decode）。
    private static func queryItems(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name.lowercased()] = item.value ?? ""
        }
        return result
    }

    /// 从 URL query 构造 sing-box tls outbound（vless/trojan 共用）。
    /// security=tls → 普通 TLS；security=reality → REALITY（需 pbk/sid）。
    private static func tlsFrom(query: [String: String]) -> [String: Any]? {
        let security = (query["security"] ?? "").lowercased()
        guard security == "tls" || security == "reality" else { return nil }
        var tls: [String: Any] = ["enabled": true]
        if let sni = query["sni"], !sni.isEmpty { tls["server_name"] = sni }
        if query["allowinsecure"] == "1" || query["allowinsecure"] == "true" {
            tls["insecure"] = true
        }
        if let alpn = query["alpn"], !alpn.isEmpty {
            tls["alpn"] = alpn.split(separator: ",").map { String($0) }
        }
        // 指纹：sing-box 用 utls 实现，fp 参数映射过去（不设则默认 chrome）
        if let fp = query["fp"], !fp.isEmpty {
            tls["utls"] = ["enabled": true, "fingerprint": fp]
        }
        if security == "reality" {
            var reality: [String: Any] = ["enabled": true]
            if let pbk = query["pbk"], !pbk.isEmpty { reality["public_key"] = pbk }
            if let sid = query["sid"], !sid.isEmpty { reality["short_id"] = sid }
            tls["reality"] = reality
        }
        return tls
    }

    /// 从 URL query 构造 transport（vless/trojan 共用）。
    private static func transportFrom(query: [String: String]) -> [String: Any]? {
        let network = (query["type"] ?? "tcp").lowercased()
        let host = query["host"] ?? ""
        let path = query["path"] ?? ""
        switch network {
        case "ws":
            var ws: [String: Any] = ["type": "ws", "path": path.isEmpty ? "/" : path]
            if !host.isEmpty { ws["headers"] = ["Host": host] }
            return ws
        case "grpc":
            let service = query["servicename"] ?? path
            return ["type": "grpc", "service_name": service.isEmpty ? "gun" : service]
        default:
            return nil
        }
    }

    private static func parseInt(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    // MARK: - vless://

    private static func parseVLESS(_ url: URL) -> ProxyNode? {
        // vless://id@host:port?params#name
        guard let host = url.host, let port = url.port, let uuid = url.user else { return nil }
        let name = url.fragment?.removingPercentEncoding ?? "VLESS"
        let query = queryItems(url)
        var node = ProxyNode(
            name: name,
            server: host,
            port: port,
            proxyProtocol: .vless,
            countryCode: inferCountry(from: name)
        )
        var base: [String: Any] = [
            "type": "vless",
            "server": host,
            "server_port": port,
            "uuid": uuid,
        ]
        if let flow = query["flow"], !flow.isEmpty { base["flow"] = flow }
        node.outboundJSON = makeOutboundJSON(
            base,
            tls: tlsFrom(query: query),
            transport: transportFrom(query: query)
        )
        return node
    }

    // MARK: - trojan://

    private static func parseTrojan(_ url: URL) -> ProxyNode? {
        // trojan 的标准 URI 把密码放在 userinfo 的 user 槽位：trojan://密码@host
        // 兼容少数 user:password 写法，优先取真正的 password 段
        guard let host = url.host, let port = url.port,
              let password = url.password ?? url.user
        else { return nil }
        let name = url.fragment?.removingPercentEncoding ?? "Trojan"
        let query = queryItems(url)
        var node = ProxyNode(
            name: name,
            server: host,
            port: port,
            proxyProtocol: .trojan,
            countryCode: inferCountry(from: name)
        )
        node.outboundJSON = makeOutboundJSON(
            [
                "type": "trojan",
                "server": host,
                "server_port": port,
                "password": password,
            ],
            tls: tlsFrom(query: query),
            transport: transportFrom(query: query)
        )
        return node
    }

    // MARK: - ss://

    private static func parseSS(_ uri: String) -> [ProxyNode] {
        // SIP002 的三种形态：
        // 1. ss://BASE64(method:password)@host:port#name   ← 最常见（机场主流）
        // 2. ss://BASE64(method:password@host:port)#name   ← 旧式整段编码
        // 3. ss://method:password@host:port#name           ← 明文（非标准但存在）
        guard uri.hasPrefix("ss://") else { return [] }
        let body = String(uri.dropFirst(5))

        // 拆出 #name
        let (addressPart, name): (String, String) = {
            if let hashIdx = body.firstIndex(of: "#") {
                let n = String(body[hashIdx...].dropFirst()).removingPercentEncoding ?? "Shadowsocks"
                return (String(body[..<hashIdx]), n)
            }
            return (body, "Shadowsocks")
        }()

        // 形态 1/3：@ 之前是凭证
        if let atIdx = addressPart.firstIndex(of: "@") {
            let credPart = String(addressPart[..<atIdx])
            let hostPart = String(addressPart[addressPart.index(after: atIdx)...])
            // 凭证可能是 base64 编码的，也可能是明文
            let credentials = decodeBase64(credPart) ?? credPart
            return [parseSSPlain("\(credentials)@\(hostPart)", name: name)].compactMap { $0 }
        }

        // 形态 2：整段 base64
        if let decoded = decodeBase64(addressPart), decoded.contains(":") {
            return [parseSSPlain(decoded, name: name)].compactMap { $0 }
        }

        return []
    }

    private static func parseSSPlain(_ decoded: String, name: String) -> ProxyNode? {
        // method:password@host:port
        guard let atIdx = decoded.firstIndex(of: "@") else { return nil }
        let credentials = String(decoded[..<atIdx])
        let remainder = String(decoded[atIdx...].dropFirst())

        guard let colonIdx = remainder.lastIndex(of: ":"),
              let port = Int(remainder[remainder.index(after: colonIdx)...])
        else { return nil }

        let server = String(remainder[..<colonIdx])

        // credentials 形如 method:password（密码本身可能含冒号，只拆第一个）
        guard let methodColon = credentials.firstIndex(of: ":") else { return nil }
        let method = String(credentials[..<methodColon])
        let password = String(credentials[credentials.index(after: methodColon)...])
        guard !method.isEmpty, !password.isEmpty else { return nil }

        var node = ProxyNode(
            name: name,
            server: server,
            port: port,
            proxyProtocol: .shadowsocks,
            countryCode: inferCountry(from: name)
        )
        node.outboundJSON = makeOutboundJSON([
            "type": "shadowsocks",
            "server": server,
            "server_port": port,
            "method": method,
            "password": password,
        ])
        return node
    }

    // MARK: - hysteria2://

    private static func parseHysteria2(_ url: URL) -> ProxyNode? {
        // 同 trojan：密码在 user 槽位
        guard let host = url.host, let port = url.port,
              let password = url.password ?? url.user
        else { return nil }
        let name = url.fragment?.removingPercentEncoding ?? "Hysteria2"
        let query = queryItems(url)
        var node = ProxyNode(
            name: name,
            server: host,
            port: port,
            proxyProtocol: .hysteria2,
            countryCode: inferCountry(from: name)
        )
        // hysteria2 强制 TLS；query 无 security 字段时按开启处理，sni 缺省用服务器域名
        var tls: [String: Any] = ["enabled": true]
        if let sni = query["sni"], !sni.isEmpty { tls["server_name"] = sni }
        if query["insecure"] == "1" || query["insecure"] == "true" { tls["insecure"] = true }
        node.outboundJSON = makeOutboundJSON(
            [
                "type": "hysteria2",
                "server": host,
                "server_port": port,
                "password": password,
            ],
            tls: tls
        )
        return node
    }

    // MARK: - SIP008 JSON

    private static func parseJSONDetailed(_ text: String) -> ParseResult? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let servers = json["servers"] as? [[String: Any]] ?? json["outbounds"] as? [[String: Any]]
        guard let serverList = servers else { return nil }

        var nodes: [ProxyNode] = []
        var skipped: [String] = []

        for dict in serverList {
            let name = dict["remarks"] as? String ?? dict["tag"] as? String ?? "Node"
            let typeString = (dict["type"] as? String ?? dict["protocol"] as? String ?? "").lowercased()

            // sing-box 完整配置里的 selector/urltest/direct/block 不是真实节点，
            // 它们被跳过是预期行为，不该报给用户
            let structural = ["selector", "urltest", "direct", "block", "dns"]
            if structural.contains(typeString) { continue }

            guard let server = dict["server"] as? String ?? dict["address"] as? String,
                  let port = parsePort(dict["server_port"] ?? dict["port"])
            else {
                skipped.append("\(name)：缺少服务器地址或端口")
                continue
            }

            let proto = ProxyProtocol(rawValue: typeString) ?? .shadowsocks
            var node = ProxyNode(
                name: name,
                server: server,
                port: port,
                proxyProtocol: proto,
                countryCode: inferCountry(from: name)
            )

            if dict["type"] != nil {
                // sing-box 完整 outbound：原样直通，凭证零丢失。
                // tag 会被 ConfigBuilder 覆盖为显示名，这里原样保留无所谓。
                node.outboundJSON = makeOutboundJSON(dict)
            } else if let method = dict["method"] as? String,
                      let password = dict["password"] as? String {
                // SIP008 的 shadowsocks 条目携带 method/password，手动组装完整 outbound
                node.outboundJSON = makeOutboundJSON([
                    "type": "shadowsocks",
                    "server": server,
                    "server_port": port,
                    "method": method,
                    "password": password,
                ])
            }

            guard node.outboundJSON != nil else {
                skipped.append("\(name)：缺少可用凭证")
                continue
            }
            nodes.append(node)
        }

        guard !nodes.isEmpty || !skipped.isEmpty else { return nil }
        return ParseResult(nodes: nodes, skipped: skipped)
    }

    // MARK: - Clash YAML

    /// 委托给 ClashConverter：它能读懂嵌套的 ws-opts / reality-opts / plugin-opts，
    /// 并产出带完整凭证的 outboundJSON。旧版扁平行扫描只能读出名字和端口，
    /// 生成的节点在 ConfigBuilder 里会被静默丢弃（节点看得见但连不上）。
    private static func parseClashDetailed(_ text: String) -> ParseResult? {
        let proxies = ClashConverter.parseProxies(text)
        guard !proxies.isEmpty else { return nil }

        var nodes: [ProxyNode] = []
        var skipped: [String] = []

        for dict in proxies {
            let name = (dict["name"] as? String) ?? "未命名节点"
            let typeRaw = (dict["type"] as? String) ?? ""

            guard let server = dict["server"] as? String, !server.isEmpty,
                  let port = parsePort(dict["port"])
            else {
                skipped.append("\(name)：缺少服务器地址或端口")
                continue
            }
            // 不支持的协议直接丢弃而不是降级成 ss ——
            // 造一个连不上的节点比少一个节点更糟
            guard let proto = ClashConverter.proxyProtocol(for: typeRaw) else {
                skipped.append("\(name)：\(typeRaw.isEmpty ? "未知" : typeRaw) 协议不支持")
                continue
            }
            guard let outbound = ClashConverter.outbound(from: dict) else {
                skipped.append("\(name)：\(typeRaw) 缺少必填凭证")
                continue
            }

            var node = ProxyNode(
                name: name,
                server: server,
                port: port,
                proxyProtocol: proto,
                countryCode: inferCountry(from: name)
            )
            node.outboundJSON = makeOutboundJSON(outbound)
            nodes.append(node)
        }

        guard !nodes.isEmpty || !skipped.isEmpty else { return nil }
        return ParseResult(nodes: nodes, skipped: skipped)
    }

    // MARK: - 工具

    private static func decodeBase64(_ str: String) -> String? {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = paddedBase64(cleaned)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func paddedBase64(_ str: String) -> String {
        let pad = (4 - str.count % 4) % 4
        return str + String(repeating: "=", count: pad)
    }

    private static func parsePort(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    /// 从节点名里推断国家码。设计稿里的节点名如「香港 IEPL 01」「日本 东京 BGP」。
    /// 只做最简单匹配，不保证全对，返回 nil 时 UI 不显示国旗。
    private static func inferCountry(from name: String) -> String? {
        let map: [String: [String]] = [
            "HK": ["香港", "HK", "Hong Kong"],
            "JP": ["日本", "JP", "Japan", "Tokyo", "Osaka"],
            "SG": ["新加坡", "SG", "Singapore"],
            "US": ["美国", "US", "USA", "United States", "Los Angeles", "San Jose", "New York"],
            "TW": ["台湾", "TW", "Taiwan"],
            "KR": ["韩国", "KR", "Korea", "Seoul"],
            "DE": ["德国", "DE", "Germany", "Frankfurt"],
            "GB": ["英国", "UK", "GB", "Britain", "London"],
            "FR": ["法国", "FR", "France", "Paris"],
            "NL": ["荷兰", "NL", "Netherlands"],
            "CA": ["加拿大", "CA", "Canada"],
            "AU": ["澳大利亚", "AU", "Australia"],
        ]
        for (code, keywords) in map {
            if keywords.contains(where: { name.localizedStandardContains($0) }) {
                return code
            }
        }
        return nil
    }
}
