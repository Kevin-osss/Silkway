import Foundation

/// Clash / Clash.Meta 配置 → sing-box outbound 的转换器。
///
/// 为什么单独一个文件：机场的 Clash YAML 是**除分享链接外最主流**的订阅格式，
/// 而它的节点字段（ws-opts / reality-opts / plugin-opts）是嵌套结构，
/// 用扁平的行扫描读不出来。凭证读不全 = 节点看得见但连不上，
/// 所以这里实现一个够用的 YAML 子集解析 + 完整的字段映射。
///
/// 不引入第三方 YAML 库的原因：机场 YAML 只用到映射/列表/标量三种结构，
/// 引入依赖换来的是 GPL 兼容性审查和二进制体积，不划算。
enum ClashConverter {

    // MARK: - 对外入口

    /// 从整份 Clash 配置文本里提取 proxies 列表，每项是保留嵌套结构的字典。
    static func parseProxies(_ text: String) -> [[String: Any]] {
        switch extractProxiesBlock(text) {
        case .absent:
            return []
        case .flow(let raw):
            // proxies: [{...}, {...}] 写在一行里
            return splitTopLevel(unwrapBrackets(raw), separator: ",")
                .map { parseFlowMapping($0) }
                .filter { !$0.isEmpty }
        case .lines(let lines):
            return parseSequenceOfMappings(lines).filter { !$0.isEmpty }
        }
    }

    /// Clash 节点字典 → sing-box outbound 字典。
    /// 返回 nil 表示该协议无法转换（例如 ssr / snell，sing-box 不支持）。
    static func outbound(from clash: [String: Any]) -> [String: Any]? {
        guard let server = string(clash["server"]), !server.isEmpty,
              let port = int(clash["port"])
        else { return nil }

        let type = (string(clash["type"]) ?? "").lowercased()
        var out: [String: Any] = ["server": server, "server_port": port]

        switch type {
        case "ss", "shadowsocks":
            out["type"] = "shadowsocks"
            guard let cipher = string(clash["cipher"]) ?? string(clash["method"]),
                  let password = string(clash["password"])
            else { return nil }
            out["method"] = cipher
            out["password"] = password
            if let plugin = pluginFields(clash) {
                out.merge(plugin) { a, _ in a }
            }

        case "vmess":
            out["type"] = "vmess"
            guard let uuid = string(clash["uuid"]) else { return nil }
            out["uuid"] = uuid
            out["alter_id"] = int(clash["alterId"]) ?? int(clash["alter_id"]) ?? 0
            out["security"] = string(clash["cipher"]) ?? "auto"
            if let tls = tlsFields(clash, defaultEnabled: false) { out["tls"] = tls }
            if let transport = transportFields(clash) { out["transport"] = transport }

        case "vless":
            out["type"] = "vless"
            guard let uuid = string(clash["uuid"]) else { return nil }
            out["uuid"] = uuid
            if let flow = string(clash["flow"]), !flow.isEmpty { out["flow"] = flow }
            // vless 没有 TLS 就是明文，但机场几乎都开；reality 也走这里
            if let tls = tlsFields(clash, defaultEnabled: false) { out["tls"] = tls }
            if let transport = transportFields(clash) { out["transport"] = transport }

        case "trojan":
            out["type"] = "trojan"
            guard let password = string(clash["password"]) else { return nil }
            out["password"] = password
            // trojan 协议本身强制 TLS，Clash 里通常不写 tls: true
            out["tls"] = tlsFields(clash, defaultEnabled: true) ?? ["enabled": true]
            if let transport = transportFields(clash) { out["transport"] = transport }

        case "hysteria2", "hy2":
            out["type"] = "hysteria2"
            guard let password = string(clash["password"]) ?? string(clash["auth"]) else { return nil }
            out["password"] = password
            if let obfs = string(clash["obfs"]), !obfs.isEmpty {
                var o: [String: Any] = ["type": obfs]
                if let pw = string(clash["obfs-password"]) { o["password"] = pw }
                out["obfs"] = o
            }
            if let up = string(clash["up"]) { out["up_mbps"] = bandwidthMbps(up) }
            if let down = string(clash["down"]) { out["down_mbps"] = bandwidthMbps(down) }
            out["tls"] = tlsFields(clash, defaultEnabled: true) ?? ["enabled": true]

        case "tuic":
            out["type"] = "tuic"
            guard let uuid = string(clash["uuid"]) else { return nil }
            out["uuid"] = uuid
            if let password = string(clash["password"]) { out["password"] = password }
            if let cc = string(clash["congestion-controller"]) { out["congestion_control"] = cc }
            if let mode = string(clash["udp-relay-mode"]) { out["udp_relay_mode"] = mode }
            out["tls"] = tlsFields(clash, defaultEnabled: true) ?? ["enabled": true]

        case "anytls":
            out["type"] = "anytls"
            guard let password = string(clash["password"]) else { return nil }
            out["password"] = password
            out["tls"] = tlsFields(clash, defaultEnabled: true) ?? ["enabled": true]

        case "socks5", "socks":
            out["type"] = "socks"
            out["version"] = "5"
            if let user = string(clash["username"]), !user.isEmpty { out["username"] = user }
            if let pw = string(clash["password"]), !pw.isEmpty { out["password"] = pw }

        case "http", "https":
            out["type"] = "http"
            if let user = string(clash["username"]), !user.isEmpty { out["username"] = user }
            if let pw = string(clash["password"]), !pw.isEmpty { out["password"] = pw }
            if let tls = tlsFields(clash, defaultEnabled: type == "https") { out["tls"] = tls }

        default:
            // ssr / snell / wireguard 等：sing-box 要么不支持，要么字段差异大到不该猜
            return nil
        }

        return out
    }

    /// Clash 的 type 字段 → 内部协议枚举。返回 nil 表示不支持。
    static func proxyProtocol(for type: String) -> ProxyProtocol? {
        switch type.lowercased() {
        case "ss", "shadowsocks": return .shadowsocks
        case "vmess": return .vmess
        case "vless": return .vless
        case "trojan": return .trojan
        case "hysteria2", "hy2": return .hysteria2
        case "tuic": return .tuic
        case "socks5", "socks": return .socks
        case "http", "https": return .http
        case "anytls": return .anytls
        default: return nil
        }
    }

    // MARK: - TLS / 传输层映射

    /// Clash 的 TLS 相关字段散落在顶层（tls / sni / servername / skip-cert-verify /
    /// client-fingerprint / alpn）和 reality-opts 里，这里统一收拢。
    private static func tlsFields(_ clash: [String: Any], defaultEnabled: Bool) -> [String: Any]? {
        // reality-opts 存在即意味着走 TLS：不少机场的 vless+reality 节点不写 tls: true，
        // 若因此返回 nil，reality 参数和 SNI 全丢，节点退化成明文 VLESS ——
        // 配置能过 check，连接必死（2026-09-09 审查实测）。
        let hasReality = clash["reality-opts"] is [String: Any]
        let enabled = bool(clash["tls"]) ?? (defaultEnabled || hasReality)
        guard enabled else { return nil }

        var tls: [String: Any] = ["enabled": true]
        // servername（vmess/vless）和 sni（trojan/hysteria2）是同一个东西的两种写法
        if let sni = string(clash["servername"]) ?? string(clash["sni"]) ?? string(clash["peer"]),
           !sni.isEmpty {
            tls["server_name"] = sni
        }
        if bool(clash["skip-cert-verify"]) == true { tls["insecure"] = true }
        if let alpn = stringArray(clash["alpn"]), !alpn.isEmpty { tls["alpn"] = alpn }
        if let fp = string(clash["client-fingerprint"]), !fp.isEmpty, fp != "none" {
            tls["utls"] = ["enabled": true, "fingerprint": fp]
        }
        if let reality = clash["reality-opts"] as? [String: Any] {
            var r: [String: Any] = ["enabled": true]
            if let pbk = string(reality["public-key"]), !pbk.isEmpty { r["public_key"] = pbk }
            if let sid = string(reality["short-id"]), !sid.isEmpty { r["short_id"] = sid }
            tls["reality"] = r
            // REALITY 必须配 utls，Clash 不写时补 chrome（sing-box 会拒绝没有 utls 的 reality）
            if tls["utls"] == nil {
                tls["utls"] = ["enabled": true, "fingerprint": "chrome"]
            }
        }
        return tls
    }

    /// network + 对应的 *-opts → sing-box transport。
    /// 兼容老写法（ws-path / ws-headers）和新写法（ws-opts.path / ws-opts.headers）。
    private static func transportFields(_ clash: [String: Any]) -> [String: Any]? {
        let network = (string(clash["network"]) ?? "tcp").lowercased()
        switch network {
        case "ws":
            let opts = clash["ws-opts"] as? [String: Any] ?? [:]
            var ws: [String: Any] = ["type": "ws"]
            let path = string(opts["path"]) ?? string(clash["ws-path"]) ?? "/"
            ws["path"] = path
            var headers: [String: Any] = [:]
            if let h = opts["headers"] as? [String: Any] {
                for (k, v) in h { if let s = string(v) { headers[k] = s } }
            } else if let h = clash["ws-headers"] as? [String: Any] {
                for (k, v) in h { if let s = string(v) { headers[k] = s } }
            }
            if !headers.isEmpty { ws["headers"] = headers }
            // Clash 的 max-early-data / early-data-header-name 对应 sing-box 的同名概念
            if let ed = int(opts["max-early-data"]) { ws["max_early_data"] = ed }
            if let edh = string(opts["early-data-header-name"]) { ws["early_data_header_name"] = edh }
            return ws

        case "grpc":
            let opts = clash["grpc-opts"] as? [String: Any] ?? [:]
            let service = string(opts["grpc-service-name"]) ?? string(clash["grpc-service-name"]) ?? "gun"
            return ["type": "grpc", "service_name": service]

        case "h2", "http":
            let opts = clash["h2-opts"] as? [String: Any] ?? clash["http-opts"] as? [String: Any] ?? [:]
            var h: [String: Any] = ["type": "http"]
            if let hosts = stringArray(opts["host"]), !hosts.isEmpty { h["host"] = hosts }
            if let path = string(opts["path"]) { h["path"] = path }
            else if let paths = stringArray(opts["path"]), let first = paths.first { h["path"] = first }
            return h

        case "httpupgrade":
            let opts = clash["http-upgrade-opts"] as? [String: Any] ?? [:]
            var h: [String: Any] = ["type": "httpupgrade"]
            if let host = string(opts["host"]) { h["host"] = host }
            if let path = string(opts["path"]) { h["path"] = path }
            return h

        default:
            return nil // tcp 不需要 transport 字段
        }
    }

    /// shadowsocks 的混淆插件。simple-obfs / v2ray-plugin 两种主流写法。
    private static func pluginFields(_ clash: [String: Any]) -> [String: Any]? {
        guard let plugin = string(clash["plugin"]), !plugin.isEmpty else { return nil }
        let opts = clash["plugin-opts"] as? [String: Any] ?? [:]

        switch plugin {
        case "obfs", "simple-obfs":
            var parts: [String] = []
            if let mode = string(opts["mode"]) { parts.append("obfs=\(mode)") }
            if let host = string(opts["host"]) { parts.append("obfs-host=\(host)") }
            return ["plugin": "obfs-local", "plugin_opts": parts.joined(separator: ";")]

        case "v2ray-plugin":
            var parts: [String] = []
            if let mode = string(opts["mode"]) { parts.append("mode=\(mode)") }
            if bool(opts["tls"]) == true { parts.append("tls") }
            if let host = string(opts["host"]) { parts.append("host=\(host)") }
            if let path = string(opts["path"]) { parts.append("path=\(path)") }
            return ["plugin": "v2ray-plugin", "plugin_opts": parts.joined(separator: ";")]

        default:
            return nil
        }
    }

    /// hysteria2 的带宽写法 "100 Mbps" / "100" / "1 Gbps" / "1.5 Gbps" → Mbps 整数。
    /// 小数点必须保留：只筛 isNumber 的话 "0.5 Gbps" 会变成 5 → 5000（应为 500）。
    private static func bandwidthMbps(_ raw: String) -> Int {
        let lower = raw.lowercased()
        let numeric = lower.filter { $0.isNumber || $0 == "." }
        guard let value = Double(numeric), value > 0 else { return 0 }
        let isGbps = lower.contains("gbps") || lower.contains("gb") ||
                     (lower.contains("g") && !lower.contains("m"))
        return Int((value * (isGbps ? 1000 : 1)).rounded())
    }

    // MARK: - YAML 子集解析

    /// proxies 块的三种形态。
    private enum ProxiesBlock {
        case absent
        case flow(String)     // proxies: [{...}, {...}]
        case lines([String])  // 块式列表
    }

    /// 截出 proxies 块。
    ///
    /// 两个必须小心的地方（均为 2026-09-09 审查实测出的真实缺陷）：
    /// 1. 只认**顶层** key。proxy-groups 里嵌套的 `proxies:` 字段很常见，
    ///    不看缩进的话会先命中它，把策略组的节点名列表当成节点定义读，
    ///    真正的 proxies 块永远读不到 → 整份订阅 0 节点。
    /// 2. 块结束判定不能只看「顶格且非空」。YAML 允许序列项与父 key 同列：
    ///        proxies:
    ///        - name: A          ← 缩进为 0，但它是内容而非下一个 key
    ///    误判为结束同样导致 0 节点。
    private static func extractProxiesBlock(_ text: String) -> ProxiesBlock {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }

        var startIndex: Int?
        for (i, line) in lines.enumerated() {
            guard indent(of: line) == 0 else { continue }   // 只认顶层 key
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("proxies:") || trimmed.hasPrefix("Proxy:") else { continue }

            let rest = trimmed.drop(while: { $0 != ":" }).dropFirst()
                .trimmingCharacters(in: .whitespaces)
            if rest == "[]" { return .absent }
            if rest.hasPrefix("[") { return .flow(rest) }
            startIndex = i
            break
        }

        guard let start = startIndex else { return .absent }

        var result: [String] = []
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                result.append(line)
                continue
            }
            // 顶格且不是序列项 = 下一个顶层 key，proxies 块结束
            if indent(of: line) == 0, !trimmed.hasPrefix("- "), trimmed != "-" {
                break
            }
            result.append(line)
        }

        return result.isEmpty ? .absent : .lines(result)
    }

    private static func unwrapBrackets(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") { text = String(text.dropFirst()) }
        if text.hasSuffix("]") { text = String(text.dropLast()) }
        return text
    }

    /// 把 `- key: value` 形式的列表解析成字典数组。
    private static func parseSequenceOfMappings(_ lines: [String]) -> [[String: Any]] {
        // 先确定列表项的基准缩进（第一个 "- " 的位置）。
        // 不看缩进就按 "- " 切分的话，字段内部的嵌套列表会被误判成新节点：
        //     - name: A
        //       alpn:
        //         - h2          ← 这行会被当成新节点，把 A 截断
        // 实测：2 个节点的 YAML 会被解成 4 个条目，且 alpn 字段全丢（2026-09-09）。
        // 探测基准缩进时必须同时认 "- x" 和单独一行的 "-"，
        // 否则后者的 baseIndent 会退化为 0，导致所有条目都不被识别
        let baseIndent = lines
            .first {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("- ") || t == "-"
            }
            .map { indent(of: $0) } ?? 0

        var items: [[String]] = []
        var current: [String] = []
        // 用显式标志而不是 `current.isEmpty` 判断是否已进入某个条目：
        // 序列项允许写成单独一行的 "-"，字段全在下一行起。
        // 用 isEmpty 判断的话这种写法会让后续字段全部被丢弃，节点凭空消失。
        var started = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // 只有缩进不深于基准的 "- " 才是新条目，更深的属于当前条目的嵌套列表
            let isNewItem = (trimmed.hasPrefix("- ") || trimmed == "-") && indent(of: line) <= baseIndent

            if isNewItem {
                if started { items.append(current) }
                started = true
                current = []
                // 去掉 "- " 前缀但保留缩进对齐：用等量空格替换，
                // 这样后续键与首键处于同一缩进层级
                let leading = String(repeating: " ", count: baseIndent + 2)
                let rest = String(trimmed.dropFirst(trimmed == "-" ? 1 : 2))
                if !rest.isEmpty { current.append(leading + rest) }
            } else if started {
                current.append(line)
            }
        }
        if started { items.append(current) }

        return items.compactMap { parseItem($0) }
    }

    /// 单个列表项 → 字典。内联流式 `{...}` 和缩进块式都支持。
    private static func parseItem(_ lines: [String]) -> [String: Any]? {
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }

        // 内联：{name: x, type: vmess, ws-opts: {path: /y}}
        if first.hasPrefix("{") {
            let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return parseFlowMapping(joined)
        }

        var index = 0
        let entries = lines.map { (indent: indent(of: $0), text: $0.trimmingCharacters(in: .whitespaces)) }
        return parseBlockMapping(entries, index: &index, minIndent: entries.first?.indent ?? 0)
    }

    /// 缩进块式映射的递归解析。
    private static func parseBlockMapping(
        _ entries: [(indent: Int, text: String)],
        index: inout Int,
        minIndent: Int
    ) -> [String: Any] {
        var result: [String: Any] = [:]

        while index < entries.count {
            let entry = entries[index]
            if entry.indent < minIndent { break }

            guard let colonIdx = entry.text.firstIndex(of: ":") else { index += 1; continue }
            let key = String(entry.text[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(entry.text[entry.text.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            index += 1

            if rawValue.isEmpty {
                // 值在下面的缩进块里：可能是嵌套映射，也可能是列表
                if index < entries.count {
                    let next = entries[index]
                    // 块序列允许与父 key **同缩进**（合法 YAML）：
                    //     alpn:
                    //     - h2
                    // 只收 indent 严格更深的话，这种写法的 alpn 会静默丢失
                    // （tuic/hysteria2 丢了 h3 alpn 就连不上）。条目已在上层按
                    // baseIndent 切分，此处的 "- " 不可能是兄弟节点，可安全收取。
                    if next.text.hasPrefix("- "), next.indent >= entry.indent {
                        var list: [String] = []
                        while index < entries.count, entries[index].text.hasPrefix("- "),
                              entries[index].indent >= entry.indent {
                            list.append(scalar(String(entries[index].text.dropFirst(2))))
                            index += 1
                        }
                        result[key] = list
                    } else if next.indent > entry.indent {
                        result[key] = parseBlockMapping(entries, index: &index, minIndent: next.indent)
                    }
                }
            } else if rawValue.hasPrefix("{") {
                result[key] = parseFlowMapping(rawValue)
            } else if rawValue.hasPrefix("[") {
                result[key] = parseFlowSequence(rawValue)
            } else {
                result[key] = scalar(rawValue)
            }
        }

        return result
    }

    /// 流式映射 `{a: 1, b: {c: 2}}` 的解析。手写而非正则：嵌套括号正则处理不了。
    private static func parseFlowMapping(_ raw: String) -> [String: Any] {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("{") else { return [:] }
        text = String(text.dropFirst())
        if text.hasSuffix("}") { text = String(text.dropLast()) }

        var result: [String: Any] = [:]
        for segment in splitTopLevel(text, separator: ",") {
            guard let colonIdx = segment.firstIndex(of: ":") else { continue }
            let key = String(segment[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = String(segment[segment.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if value.hasPrefix("{") {
                result[key] = parseFlowMapping(value)
            } else if value.hasPrefix("[") {
                result[key] = parseFlowSequence(value)
            } else {
                result[key] = scalar(value)
            }
        }
        return result
    }

    private static func parseFlowSequence(_ raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("[") else { return [] }
        text = String(text.dropFirst())
        if text.hasSuffix("]") { text = String(text.dropLast()) }
        return splitTopLevel(text, separator: ",")
            .map { scalar($0) }
            .filter { !$0.isEmpty }
    }

    /// 按分隔符切分，但跳过括号内和引号内的分隔符。
    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var segments: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?

        for char in text {
            if let q = quote {
                current.append(char)
                if char == q { quote = nil }
                continue
            }
            switch char {
            case "\"", "'":
                quote = char
                current.append(char)
            case "{", "[":
                depth += 1
                current.append(char)
            case "}", "]":
                depth -= 1
                current.append(char)
            case separator where depth == 0:
                segments.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { segments.append(current) }
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 标量清洗：去引号、去行尾注释。
    ///
    /// 顺序很重要：**先找配对引号，再谈注释**。
    /// 早期实现先判首尾引号，遇到 `"a.com"  # 注释` 时尾部还挂着注释，
    /// 引号判断失败 → 值变成带引号的 `"a.com"`。最致命的是 `tls: "true"  # x`：
    /// bool() 收到带引号的字符串返回 nil，**整个 tls 块被丢弃**，
    /// 配置仍能过 sing-box check，但运行时必然握手失败（2026-09-09 审查实测）。
    /// 引号内的 ` #` 不能当注释，未加引号的密码里的 `#`（如 `pa#ss`）也要保留。
    private static func scalar(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let quote = text.first, quote == "\"" || quote == "'" else {
            // 未加引号：只剥「空格 + #」形式的行尾注释
            if let range = text.range(of: " #") {
                return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return text
        }

        // 引号开头：取到配对的收尾引号为止，其后内容（含注释）一律忽略
        var content = ""
        var closed = false
        for ch in text.dropFirst() {
            if ch == quote { closed = true; break }
            content.append(ch)
        }
        return closed ? content : text
    }

    private static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    // MARK: - 类型转换

    private static func string(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func bool(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let s = (any as? String)?.lowercased() {
            if ["true", "yes", "on", "1"].contains(s) { return true }
            if ["false", "no", "off", "0"].contains(s) { return false }
        }
        return nil
    }

    private static func stringArray(_ any: Any?) -> [String]? {
        if let arr = any as? [String] { return arr }
        if let s = any as? String, !s.isEmpty {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}
