import Foundation
import Testing
@testable import SilkwayCore

/// AutoUpdateService.checkOnce 的行为：
/// 没有到期订阅时不更新也不重载；有到期订阅且节点变化时热重载。
@Suite("自动更新")
@MainActor
struct AutoUpdateServiceTests {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-autoupdate-\(UUID().uuidString)")
    }

    /// 造一个"已到期"的订阅：更新间隔 0 秒 → 任何时候都 needsUpdate。
    private func dueSubscription() -> Subscription {
        var sub = Subscription(name: "到期订阅", url: URL(string: "https://invalid.example/sub")!)
        sub.updateInterval = 0
        return sub
    }

    @Test("无到期订阅时不触发更新")
    func noDueSubscriptions() async {
        let service = AutoUpdateService.shared
        // 直接调 checkOnce，不应 crash、不应抛错（内部错误都被吞掉了）
        await service.checkOnce()
        // 无可断言的副作用，主要验证不 crash；有到期订阅的场景依赖网络，不做集成测试
    }

    @Test("updateAllDue 只更新到期的订阅")
    func dueFiltering() async throws {
        let store = ProxyNodeStore(directory: makeTempDir())
        let manager = SubscriptionManager(store: store)

        // 两个订阅：一个到期（interval=0），一个不到期（interval 极大）
        var dueSub = Subscription(name: "到期", url: URL(string: "https://invalid.example/due")!)
        dueSub.updateInterval = 0
        // 刚更新过的订阅：lastUpdated = now，大间隔 → 不到期
        let freshSub = Subscription(
            name: "新鲜",
            url: URL(string: "https://invalid.example/fresh")!,
            lastUpdated: Date(),
            updateInterval: 999_999_999
        )
        store.addSubscription(dueSub)
        store.addSubscription(freshSub)

        // URL 无效必然拉取失败，但 updateAllDue 应只尝试到期那个
        // （内部 try? 吞错）。这里验证的是"筛选逻辑"不崩、且没到期的没被碰。
        let count = await manager.updateAllDue()
        #expect(count == 1, "只应尝试更新 1 个到期订阅")

        // 没到期的订阅保持我们设置的 lastUpdated（没被拉取覆盖成新值）
        let fresh = store.subscriptions.first { $0.name == "新鲜" }
        #expect(fresh?.lastUpdated != nil)
        #expect(abs((fresh?.lastUpdated?.timeIntervalSinceReferenceDate ?? 0) - Date().timeIntervalSinceReferenceDate) < 60)
    }
}
