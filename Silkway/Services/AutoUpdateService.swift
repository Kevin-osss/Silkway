import Foundation

/// 后台自动更新订阅。
///
/// 启动时立即检查一次，之后每 30 分钟检查一次（只看"到期"的订阅，
/// 没设更新间隔的订阅不碰）。更新成功后如果内核在跑就热重载配置。
///
/// 用 Task + sleep 而不是 Timer：Timer 需要 RunLoop，而 async 环境
/// 里直接 sleep + cancellation 更干净。
@MainActor
final class AutoUpdateService {

    static let shared = AutoUpdateService()

    /// 检查周期。启动立刻查一次，之后按这个间隔轮询。
    var checkInterval: TimeInterval = 30 * 60

    private var task: Task<Void, Never>?

    private init() {}

    /// 在 App 启动时调用一次。
    func start() {
        guard task == nil else { return } // 防重复启动
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkOnce()
                try? await Task.sleep(nanoseconds: UInt64(self.checkInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// 跑一轮"到期订阅更新 + 热重载"。独立出来是为了测试和手动触发。
    func checkOnce() async {
        let manager = SubscriptionManager.shared
        // 用节点名集合比较：同名视为同节点，避免 UUID 每次刷新都变的误报
        let before = Set(manager.allNodes.map(\.name))
        let updated = await manager.updateAllDue()
        guard updated > 0 else { return }

        let after = Set(manager.allNodes.map(\.name))
        if after != before {
            await SingBoxManager.shared.reloadConfigIfRunning()
        }
    }

    /// 确保分流规则集已下载（「绕过中国大陆」默认开启后，首次启动时自动下载）。
    /// 失败不阻塞启动 —— 规则不注入，行为等于没开分流，可以之后重试。
    func ensureRuleSetsIfNeeded() async {
        guard AppConfigStore.shared.config.bypassChinaMainland else { return }
        guard !RuleSetManager.shared.bypassCNReady else { return }
        try? await RuleSetManager.shared.downloadCNRuleSets()
        // 下载完成后如果内核在跑，热重载让分流规则立即生效
        if RuleSetManager.shared.bypassCNReady {
            await SingBoxManager.shared.reloadConfigIfRunning()
        }
    }
}
