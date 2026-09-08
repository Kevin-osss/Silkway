import Foundation
import Observation

/// 订阅管理器。
///
/// 负责：
///   1. 从 URL 拉取订阅原始文本
///   2. 解析为 ProxyNode 数组
///   3. 通过 ProxyNodeStore 持久化订阅元数据与节点
///   4. 按间隔自动更新
///
/// 状态单一来源是 store —— subscriptions/nodes 都是从 store 转的，
/// 改数据必须走 store 的方法（它会落盘），否则重启后丢失。
@Observable
@MainActor
final class SubscriptionManager {

    static let shared = SubscriptionManager()

    private let urlSession: URLSession
    private let store: ProxyNodeStore

    /// 已保存的订阅元数据（转 store，只读）。
    var subscriptions: [Subscription] { store.subscriptions }

    /// 所有订阅合并后的节点（供 UI / ConfigBuilder 使用）。
    var allNodes: [ProxyNode] { store.allNodes }

    init(store: ProxyNodeStore = .shared, urlSession: URLSession = .shared) {
        self.store = store
        self.urlSession = urlSession
    }

    // MARK: - 公开 API

    /// 添加并解析一个订阅。
    @discardableResult
    func addSubscription(name: String, url: URL, updateInterval: TimeInterval? = nil) async throws -> Subscription {
        var subscription = Subscription(name: name, url: url, updateInterval: updateInterval)
        let nodes = try await update(subscription: &subscription)
        store.addSubscription(subscription)
        store.replaceNodes(subscriptionID: subscription.id, with: nodes)
        return subscription
    }

    /// 手动更新单个订阅。
    @discardableResult
    func updateSubscription(id: UUID) async throws -> [ProxyNode] {
        guard var subscription = store.subscriptions.first(where: { $0.id == id }) else {
            throw SubscriptionError.subscriptionNotFound
        }
        let nodes = try await update(subscription: &subscription)
        store.updateSubscription(subscription)
        store.replaceNodes(subscriptionID: id, with: nodes)
        return nodes
    }

    /// 更新所有订阅（P1 后台自动检查复用这个）。
    func updateAll() async {
        for sub in store.subscriptions {
            _ = try? await updateSubscription(id: sub.id)
        }
    }

    /// 只更新已过更新间隔的订阅。返回更新了几个。
    @discardableResult
    func updateAllDue() async -> Int {
        var count = 0
        for sub in store.subscriptions where sub.needsUpdate() {
            _ = try? await updateSubscription(id: sub.id)
            count += 1
        }
        return count
    }

    func deleteSubscription(id: UUID) {
        store.removeSubscription(id: id)
    }

    /// 测速结果回写：更新内存中的节点并把 store 落盘。
    func recordLatency(nodeID: UUID, result: LatencyResult) {
        guard let node = store.allNodes.first(where: { $0.id == nodeID }) else { return }
        var updated = node
        switch result {
        case .timeout:
            updated.latency = nil
            updated.hasBeenTested = true
        case .value(let ms):
            updated.latency = ms
            updated.hasBeenTested = true
        case .untested:
            break
        }
        store.updateNode(updated)
    }

    // MARK: - 内部实现

    /// 拉取并解析，同时更新 subscription 的元数据。
    private func update(subscription: inout Subscription) async throws -> [ProxyNode] {
        var request = URLRequest(url: subscription.url)
        request.setValue("Silkway/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SubscriptionError.fetchFailed
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        var nodes = SubscriptionParser.parse(text)

        // 节点归属到本订阅（手动添加或解析器没设时兜底）
        for i in nodes.indices where nodes[i].subscriptionID == nil {
            nodes[i].subscriptionID = subscription.id
        }

        subscription.lastUpdated = Date()
        subscription.nodeCount = nodes.count
        subscription.lastError = nodes.isEmpty ? "订阅未解析出任何节点" : nil
        return nodes
    }
}

// MARK: - 错误

enum SubscriptionError: Error, CustomStringConvertible {
    case subscriptionNotFound
    case fetchFailed
    case invalidURL
    case emptySubscription
    case unsupportedFormat

    var description: String {
        switch self {
        case .subscriptionNotFound: return "找不到该订阅"
        case .fetchFailed:          return "拉取订阅失败"
        case .invalidURL:           return "订阅地址无效"
        case .emptySubscription:    return "订阅内容为空"
        case .unsupportedFormat:    return "无法识别订阅格式"
        }
    }
}
