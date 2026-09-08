import Testing
import Foundation
@testable import SilkwayCore

/// SingBoxManager 集成测试。
///
/// 真实启动 spike/ 下的 sing-box 二进制，验证完整生命周期：
/// start → API 就绪 → 热切节点 → 流量轮询 → stop → 端口释放。
///
/// 系统代理用 mock 替换，避免测试修改本机网络设置。
///
/// ⚠️ 必须 .serialized：Swift Testing 默认并行跑套件内测试，
/// 而两个测试共享 SingBoxManager 单例（真实 sing-box 进程），
/// 并行会互相杀掉对方进程导致挂起。
@Suite("SingBoxManager 集成", .serialized)
struct SingBoxManagerIntegrationTests {

    /// 记录 mock 系统代理的调用。
    final class MockSystemProxy: SystemProxyManaging, @unchecked Sendable {
        var enableCalls: [(host: String, port: Int)] = []
        var disableCallCount = 0

        func enable(host: String, port: Int) async throws {
            enableCalls.append((host, port))
        }

        func disable() async {
            disableCallCount += 1
        }
    }

    @Test("完整生命周期：启动 → 切换 → 停止")
    @MainActor
    func fullLifecycle() async throws {
        let manager = SingBoxManager.shared
        let mock = MockSystemProxy()
        manager.systemProxy = mock

        // 指向 spike 里的真实二进制
        manager.singBoxBinaryURL = URL(fileURLWithPath:
            "/Users/kevinwang/vibeCoding/Silkway/spike/sing-box")

        // 隔离工作目录：不与运行中的 Silkway App 抢 cache.db 文件锁，
        // 也不覆盖 App 的真实 config.json
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-mgr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        manager.appSupportDir = workDir
        // 注入空节点：selector 只含 direct-out，测试结果与真实订阅无关
        manager.nodeProvider = { [] }
        // 注入默认配置：否则会读到用户真实设置（如 tunEnabled=true），
        // 让测试走到需要特权的 TUN 分支上去
        manager.configProvider = { AppConfig() }

        // 防御：如果之前的测试残留了进程，先清掉
        if manager.isRunning { await manager.stop() }

        // 1. 启动
        try await manager.start()
        #expect(manager.isRunning)
        #expect(manager.currentMixedPort > 0)
        #expect(manager.currentAPIPort > 0)
        #expect(mock.enableCalls.count == 1)
        #expect(mock.enableCalls.first?.host == "127.0.0.1")
        #expect(mock.enableCalls.first?.port == Int(manager.currentMixedPort))

        // 2. API 就绪后 manager 内部状态应已更新（isRunning 已在上面验证）
        // 轮询最多 3 秒等流量快照 —— 证明 API 客户端真实在工作
        var gotTraffic = false
        for _ in 0..<30 {
            if manager.lastTraffic != nil { gotTraffic = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(gotTraffic)

        // 3. 热切节点（selector → direct-out）不应抛异常
        try await manager.switchNode(groupTag: "PROXY", nodeTag: "direct-out")

        // 5. 停止
        await manager.stop()
        #expect(!manager.isRunning)
        #expect(mock.disableCallCount == 1)

        // 6. 端口已释放：connect 应被拒（bind 会受 TIME_WAIT 干扰，不能作为判据）
        let port = manager.currentAPIPort
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connectResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // connect 失败（ECONNREFUSED = 61）= 端口已释放
        #expect(connectResult == -1)
    }

    @Test("重复 start 是幂等的")
    @MainActor
    func idempotentStart() async throws {
        let manager = SingBoxManager.shared
        manager.systemProxy = MockSystemProxy()
        manager.singBoxBinaryURL = URL(fileURLWithPath:
            "/Users/kevinwang/vibeCoding/Silkway/spike/sing-box")
        // 同样隔离工作目录（与 fullLifecycle 一致）
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-mgr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        manager.appSupportDir = workDir
        manager.nodeProvider = { [] }
        manager.configProvider = { AppConfig() }

        if manager.isRunning { await manager.stop() }
        try await manager.start()
        let port = manager.currentAPIPort
        try await manager.start()   // 第二次不应重启
        #expect(manager.currentAPIPort == port)
        await manager.stop()
        #expect(!manager.isRunning)
    }
}

