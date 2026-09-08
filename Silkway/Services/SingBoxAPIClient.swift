import Foundation

/// sing-box Clash API 客户端。
///
/// sing-box 启动后监听 127.0.0.1:<port>，暴露 Clash 兼容的 REST API。
/// 本客户端负责：获取节点、热切节点、查询连接与流量。
///
/// 使用前提：sing-box 进程已经启动且 API 端口已确定。
/// 端口由 SingBoxManager 在启动时分配并注入。
actor SingBoxAPIClient {

    /// API 基础地址，如 http://127.0.0.1:62359
    let baseURL: URL

    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - 错误

    enum APIError: Error, CustomStringConvertible {
        case invalidResponse
        case httpError(Int)
        case decodeFailed

        var description: String {
            switch self {
            case .invalidResponse: return "Clash API 响应格式无效"
            case .httpError(let code): return "Clash API 返回 HTTP \(code)"
            case .decodeFailed: return "解析 Clash API 响应失败"
            }
        }
    }

    // MARK: - 节点

    /// GET /proxies 的原始返回。
    struct ProxiesResponse: Decodable {
        let proxies: [String: ProxyInfo]
    }

    struct ProxyInfo: Decodable {
        let name: String
        let type: String
        let all: [String]?
        let now: String?
        let history: [HistoryEntry]?
    }

    struct HistoryEntry: Decodable {
        let time: String?
        let delay: Int?
    }

    /// 获取所有代理出站（节点 + 策略组）。
    func proxies() async throws -> [String: ProxyInfo] {
        let data = try await get("/proxies")
        let decoded = try JSONDecoder().decode(ProxiesResponse.self, from: data)
        return decoded.proxies
    }

    /// 热切切换 selector / fallback 的选中项。
    ///
    /// 成功后已有连接平滑迁移，无需重启进程 —— 这是技术验证任务 0 已证实的能力。
    func switchProxy(groupTag: String, to nodeTag: String) async throws {
        let body: [String: Any] = ["name": nodeTag]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let (_, status) = try await request(
            path: "/proxies/\(groupTag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupTag)",
            method: "PUT",
            body: bodyData
        )
        guard status == 204 else {
            throw APIError.httpError(status)
        }
    }

    // MARK: - 连接

    struct ConnectionsResponse: Decodable {
        let downloadTotal: Int64
        let uploadTotal: Int64
        let connections: [ConnectionInfo]?
    }

    struct ConnectionInfo: Decodable {
        let id: String
        let metadata: Metadata?
        let chains: [String]
        let rule: String?
        let rulePayload: String?
        let upload: Int64
        let download: Int64
        let start: String?
    }

    struct Metadata: Decodable {
        let network: String?
        let destinationIP: String?
        let destinationPort: String?
        let host: String?
    }

    func connections() async throws -> ConnectionsResponse {
        let data = try await get("/connections")
        return try JSONDecoder().decode(ConnectionsResponse.self, from: data)
    }

    /// 断开指定连接。
    func closeConnection(id: String) async throws {
        let (_, status) = try await request(
            path: "/connections/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)",
            method: "DELETE"
        )
        guard status == 204 else {
            throw APIError.httpError(status)
        }
    }

    // MARK: - 流量

    struct Traffic: Decodable {
        let up: Int64
        let down: Int64
    }

    /// 获取当前实时速率（bytes/s）。
    func traffic() async throws -> Traffic {
        let data = try await get("/traffic")
        return try JSONDecoder().decode(Traffic.self, from: data)
    }

    // MARK: - 版本

    struct Version: Decodable {
        let version: String
    }

    func version() async throws -> Version {
        let data = try await get("/version")
        return try JSONDecoder().decode(Version.self, from: data)
    }

    // MARK: - 运行模式

    struct ConfigsResponse: Decodable {
        let mode: String?
    }

    /// 查询当前路由模式（global / rule / direct）。
    func configs() async throws -> String? {
        let data = try await get("/configs")
        return try JSONDecoder().decode(ConfigsResponse.self, from: data).mode
    }

    /// 热切切换路由模式。
    func setMode(_ mode: ProxyMode) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue])
        let (_, status) = try await request(path: "/configs", method: "PUT", body: body)
        guard status == 204 else {
            throw APIError.httpError(status)
        }
    }

    /// 热重载配置（订阅更新、节点变更后无需重启进程）。
    /// sing-box 的 PUT /configs 带 path 字段时会从磁盘重新读配置。
    /// - Parameter path: 新配置文件在磁盘上的绝对路径
    func reloadConfig(path: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["path": path])
        let (_, status) = try await request(path: "/configs", method: "PUT", body: body)
        // 204 = 重载成功；200 = 带 force 时的响应，都接受
        guard status == 204 || status == 200 else {
            throw APIError.httpError(status)
        }
    }

    // MARK: - 单节点测速

    struct DelayResponse: Decodable {
        let delay: Int
    }

    /// 测量单个出站的延迟（走真实隧道到测试 URL）。
    /// - Returns: 毫秒延迟
    func delay(proxy name: String, timeout: TimeInterval = 5, url: String = "http://cp.cloudflare.com/generate_204") async throws -> Int {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let query = "?timeout=\(Int(timeout * 1000))&url=\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)"
        let data = try await get("/proxies/\(encoded)/delay\(query)")
        return try JSONDecoder().decode(DelayResponse.self, from: data).delay
    }

    // MARK: - 底层 HTTP

    private func get(_ path: String) async throws -> Data {
        let (data, status) = try await request(path: path, method: "GET")
        guard status == 200 else {
            throw APIError.httpError(status)
        }
        return data
    }

    private func request(path: String, method: String, body: Data? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return (data, http.statusCode)
    }
}
