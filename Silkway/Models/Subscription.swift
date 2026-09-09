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

    // MARK: - 兼容性字段
    //
    // 以下字段全部是 Optional，不是因为「可能没有值」，而是为了持久化兼容：
    // 非可选的新字段会让旧版本写入的 JSON 直接解码失败（Swift 合成的
    // init(from:) 遇到缺失的 key 会抛错，默认值救不了），用户的订阅列表会整个丢失。

    /// 最近一次更新中被跳过的条目数（协议不支持或缺必填凭证）。
    /// nil 表示旧数据未记录过。非 0 时 UI 必须提示 —— 静默丢弃节点
    /// 会让用户面对「订阅显示 50 个节点，实际能用 30 个」而无从查起。
    var skippedCount: Int?

    /// 被跳过条目的原因摘要（最多保留若干条，避免持久化膨胀）。
    var skippedReasons: [String]?

    /// 机场在 `Subscription-Userinfo` 响应头里返回的流量数据（单位：字节）。
    var trafficUpload: Int64?
    var trafficDownload: Int64?
    var trafficTotal: Int64?

    /// 套餐到期时间。同样来自 `Subscription-Userinfo`。
    var expiresAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        lastUpdated: Date? = nil,
        nodeCount: Int = 0,
        updateInterval: TimeInterval? = nil,
        lastError: String? = nil,
        skippedCount: Int? = nil,
        skippedReasons: [String]? = nil,
        trafficUpload: Int64? = nil,
        trafficDownload: Int64? = nil,
        trafficTotal: Int64? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.lastUpdated = lastUpdated
        self.nodeCount = nodeCount
        self.updateInterval = updateInterval
        self.lastError = lastError
        self.skippedCount = skippedCount
        self.skippedReasons = skippedReasons
        self.trafficUpload = trafficUpload
        self.trafficDownload = trafficDownload
        self.trafficTotal = trafficTotal
        self.expiresAt = expiresAt
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

    // MARK: - 流量 / 到期

    /// 已用流量（上行 + 下行）。机场统计口径普遍是两者相加。
    var trafficUsed: Int64? {
        guard trafficUpload != nil || trafficDownload != nil else { return nil }
        return (trafficUpload ?? 0) + (trafficDownload ?? 0)
    }

    /// 剩余流量。总量为 0 表示不限量，此时返回 nil。
    var trafficRemaining: Int64? {
        guard let total = trafficTotal, total > 0, let used = trafficUsed else { return nil }
        return max(0, total - used)
    }

    /// 已用比例 0...1，用于进度条。不限量或无数据时返回 nil。
    var trafficRatio: Double? {
        guard let total = trafficTotal, total > 0, let used = trafficUsed else { return nil }
        return min(1.0, Double(used) / Double(total))
    }

    /// 距离到期还有多少天。已过期返回负数。
    func daysUntilExpiry(now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: now, to: expiresAt).day
    }

    /// 写入机场 `Subscription-Userinfo` 响应头里的流量/到期信息。
    ///
    /// 格式（Clash 生态的事实标准）：
    ///   `upload=1234; download=5678; total=107374182400; expire=1735660800`
    /// 单位字节，expire 是 Unix 时间戳。total=0 或缺 expire 表示不限量/不过期。
    ///
    /// 放在模型上而不是 manager 里：纯字符串变换，不该为了测试它去造 URLSession。
    mutating func applyUserInfo(header raw: String) {
        var fields: [String: Int64] = [:]
        for part in raw.components(separatedBy: ";") {
            let kv = part.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            if let value = Int64(kv[1].trimmingCharacters(in: .whitespaces)) {
                fields[key] = value
            }
        }
        guard !fields.isEmpty else { return }

        trafficUpload = fields["upload"]
        trafficDownload = fields["download"]
        trafficTotal = fields["total"]
        if let expire = fields["expire"], expire > 0 {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expire))
        } else {
            expiresAt = nil
        }
    }
}
