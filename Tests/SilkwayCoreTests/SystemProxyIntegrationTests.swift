import Foundation
import Testing
@testable import SilkwayCore

/// 真实启用/禁用系统代理的集成测试。
///
/// ⚠️ 这个测试会真实修改系统网络设置！但会立即恢复：
/// enable → 验证 scutil 状态 → disable → 验证已关闭。
/// 这就是 2026-09-03「stdout/stderr 读反」bug 的端到端回归测试。
@Suite("系统代理真实启停", .serialized)
struct SystemProxyIntegrationTests {

    @Test("enable 后系统代理真的开启，disable 后真的关闭")
    @MainActor
    func enableDisableRoundTrip() async throws {
        let proxy = SystemProxy.shared

        // 启用（用不可能冲突的端口 17899）
        try await proxy.enable(host: "127.0.0.1", port: 17899)

        // 验证：随便挑一个服务读回状态
        let services = try await proxy.activeServices()
        #expect(!services.isEmpty)

        // 对每个服务验证 HTTP 代理已开启且指向我们的端口
        var verifiedCount = 0
        for service in services {
            let state = await proxy.httpProxyState(service: service)
            if state.enabled {
                #expect(state.host == "127.0.0.1", "服务 \(service) 代理 host 应为 127.0.0.1")
                #expect(state.port == 17899, "服务 \(service) 代理端口应为 17899")
                verifiedCount += 1
            }
        }
        #expect(verifiedCount > 0, "至少一个服务的 HTTP 代理应被启用")

        // 关闭
        await proxy.disable()

        // 验证全部关闭
        for service in services {
            let state = await proxy.httpProxyState(service: service)
            #expect(!state.enabled, "服务 \(service) 代理应已关闭")
        }
    }
}
