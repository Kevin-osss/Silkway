import Foundation

/// 机场订阅。
struct Subscription: Identifiable, Codable, Hashable, Sendable {

    let id: UUID
    var name: String

    /// 订阅地址。可以是 https:// 也可以是 file:// （设计稿里「自建节点」用的就是本地文件）。
    var url: URL

    /// 最近一次成功更新的时间。nil 表示从未成功更新过。
    var lastUpdated: Date?

    /// 最近一次更新解析出的节点数。用于 UI 显示，避免每次都去数 nodes 数组。
    var nodeCount: Int

    /// 自动更新间隔。nil 表示不自动更新。
    var updateInterval: TimeInterval?

    /// 最近一次更新的错误信息。非 nil 时 UI 应显示警告标记。
    /// 不用 Error 类型是因为 Error 不可 Codable，而这个状态需要持久化，
    /// 否则重启 App 后用户看不到「上次更新失败」。
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        lastUpdated: Date? = nil,
        nodeCount: Int = 0,
        updateInterval: TimeInterval? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.lastUpdated = lastUpdated
        self.nodeCount = nodeCount
        self.updateInterval = updateInterval
        self.lastError = lastError
    }
}

extension Subscription {

    /// 是否到了该自动更新的时间。
    func needsUpdate(now: Date = Date()) -> Bool {
        guard let updateInterval else { return false }
        guard let lastUpdated else { return true }   // 从未更新过则立即更新
        return now.timeIntervalSince(lastUpdated) >= updateInterval
    }

    /// 脱敏后的 URL，用于 UI 展示。
    ///
    /// 订阅链接里的 token / uid 等同于账号密码，直接显示在界面上，
    /// 用户截图求助时会泄露。设计稿里显示为 `https://sub.aurora.net/link?token=•••`。
    var maskedURL: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                // 仅保留参数名，值一律打码 —— 不试图判断哪些参数「敏感」，
                // 因为机场的参数命名五花八门，白名单必然有遗漏。
                URLQueryItem(name: item.name, value: item.value == nil ? nil : "•••")
            }
        }
        return components.string ?? url.absoluteString
    }
}
