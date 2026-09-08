import Foundation

/// 订阅与节点的持久化存储。
///
/// 用 JSON 文件存（不用 CoreData/SwiftData —— 数据就是一个列表，
/// 引入数据库是过度设计；也不用 UserDefaults —— 节点列表可能上百条，
/// 属于"大量数据"，手册 §4 明确禁止）。
///
/// 存储位置：`~/Library/Application Support/Silkway/store/`
/// - `subscriptions.json` —— [Subscription]
/// - `nodes.json` —— [ProxyNode]（所有订阅的节点平铺，靠 subscriptionID 关联）
///
/// 原子写入：先写临时文件再 rename，避免中途崩溃留下半个 JSON。
@Observable
@MainActor
final class ProxyNodeStore {

    static let shared = ProxyNodeStore()

    private(set) var subscriptions: [Subscription] = []
    private(set) var nodes: [ProxyNode] = []

    private let directory: URL
    private var subscriptionsURL: URL { directory.appendingPathComponent("subscriptions.json") }
    private var nodesURL: URL { directory.appendingPathComponent("nodes.json") }

    /// 测试可注入临时目录。
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("Silkway/store")
        }
        load()
    }

    // MARK: - 查询

    /// 全部节点平铺列表（ConfigBuilder、菜单栏视图用）。
    var allNodes: [ProxyNode] { nodes }

    /// 按订阅分组的节点。
    func nodes(for subscriptionID: UUID) -> [ProxyNode] {
        nodes.filter { $0.subscriptionID == subscriptionID }
    }

    // MARK: - 订阅操作

    func addSubscription(_ subscription: Subscription) {
        subscriptions.append(subscription)
        save()
    }

    /// 更新订阅元数据（拉取成功后刷新 updatedAt / nodeCount / lastError）。
    func updateSubscription(_ subscription: Subscription) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscription.id }) else { return }
        subscriptions[idx] = subscription
        save()
    }

    func removeSubscription(id: UUID) {
        subscriptions.removeAll { $0.id == id }
        nodes.removeAll { $0.subscriptionID == id }
        save()
    }

    // MARK: - 节点操作

    /// 添加手动节点（subscriptionID 为 nil，不受订阅刷新影响）。
    func addManualNode(_ node: ProxyNode) {
        nodes.append(node)
        save()
    }

    /// 删除手动节点。
    func removeManualNode(id: UUID) {
        nodes.removeAll { $0.id == id && $0.subscriptionID == nil }
        save()
    }

    /// 用新拉取的节点列表整体替换某订阅的节点（保持其他订阅的节点不动）。
    func replaceNodes(subscriptionID: UUID, with newNodes: [ProxyNode]) {
        nodes.removeAll { $0.subscriptionID == subscriptionID }
        nodes.append(contentsOf: newNodes)
        save()
    }

    /// 更新单个节点（延迟测速结果回写用）。
    func updateNode(_ node: ProxyNode) {
        guard let idx = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[idx] = node
        save()
    }

    // MARK: - 持久化

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: subscriptionsURL),
           let decoded = try? decoder.decode([Subscription].self, from: data) {
            subscriptions = decoded
        }
        if let data = try? Data(contentsOf: nodesURL),
           let decoded = try? decoder.decode([ProxyNode].self, from: data) {
            nodes = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // 目录可能不存在（首次运行）
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 原子写：临时文件 + rename
        try? atomicWrite(encoder.encode(subscriptions), to: subscriptionsURL)
        try? atomicWrite(encoder.encode(nodes), to: nodesURL)
    }

    private func atomicWrite(_ data: Data?, to url: URL) throws {
        guard let data else { return }
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
