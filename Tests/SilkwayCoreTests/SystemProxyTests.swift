import Testing
import Foundation
@testable import SilkwayCore

@Suite("系统代理解析")
struct SystemProxyParsingTests {

    @Test("解析 networksetup 的 getwebproxy 输出")
    func parseEnabled() {
        let output = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 2080
        """
        let state = SystemProxy.parseProxyState(output)
        #expect(state.enabled == true)
        #expect(state.host == "127.0.0.1")
        #expect(state.port == 2080)
    }

    @Test("解析关闭状态")
    func parseDisabled() {
        let output = """
        Enabled: No
        Server: 127.0.0.1
        Port: 0
        """
        let state = SystemProxy.parseProxyState(output)
        #expect(state.enabled == false)
    }

    @Test("空字符串返回未启用")
    func parseEmpty() {
        let state = SystemProxy.parseProxyState("")
        #expect(state.enabled == false)
        #expect(state.host == nil)
        #expect(state.port == nil)
    }
}

@Suite("系统代理服务列表")
struct SystemProxyServiceListTests {

    @Test("跳过说明行、禁用服务和占位服务")
    func activeServicesParsing() throws {
        let sample = """
        An asterisk (*) denotes that a network service is disabled.
        (null)
        Wi-Fi
        Ethernet
        *Bluetooth PAN
        *Thunderbolt Bridge
        """

        // 真正测试解析逻辑 —— parseServiceList 是 static 纯函数
        let services = try SystemProxy.parseServiceList(sample)
        #expect(services == ["Wi-Fi", "Ethernet"])
    }

    @Test("空输出抛错")
    func emptyOutputThrows() {
        #expect(throws: SystemProxy.Error.self) {
            _ = try SystemProxy.parseServiceList("")
        }
    }

    @Test("真实调用 networksetup -listallnetworkservices 不抛异常")
    func listServicesDoesNotThrow() async throws {
        // 只读操作，不会修改系统设置
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0)
        #expect(output.contains("An asterisk"))
    }

    @Test("activeServices 能读到真实服务列表（防 stdout/stderr 读反回归）")
    func activeServicesReturnsRealList() async throws {
        // 2026-09-03 真实 bug：run() 把 stdout 丢进 nullDevice 只读 stderr，
        // 而 networksetup 的数据输出全在 stdout → activeServices 永远"输出为空"。
        // 这个测试走 SystemProxy 公开 API 真实调用，而不是绕过它。
        let services = try await SystemProxy.shared.activeServices()
        #expect(!services.isEmpty, "activeServices 应返回至少一个活跃服务")
        #expect(services.contains("Wi-Fi"), "常见环境应包含 Wi-Fi")
    }
}
