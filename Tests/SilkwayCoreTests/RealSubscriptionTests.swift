import Foundation
import Testing
@testable import SilkwayCore

/// 真实订阅验证（手动触发，非常驻测试）。
///
/// 读 App 真实 store 里的节点（用户在 Silkway 设置里导入的「白月光」订阅），
/// 用真正的 ConfigBuilder 生成配置，过 sing-box check。
/// 凭证不会打印，只输出统计信息。
/// 注意：不能用 .disabled(if:) —— disabled 的 suite 连 --filter 都匹配不到，
/// 无法在导入订阅后手动触发。改为测试体内自检：store 不存在则直接通过（无验证），
/// 存在则做真实 sing-box check。
private let realStorePath = NSHomeDirectory() + "/Library/Application Support/Silkway/store/nodes.json"

@Suite("真实订阅验证")
struct RealSubscriptionTests {

    @Test("真实节点配置过 sing-box check")
    func realConfigPassesCheck() throws {
        // 本机没导入过真实订阅时跳过验证（视为通过）
        guard FileManager.default.fileExists(atPath: realStorePath) else {
            print("未找到真实订阅 store，跳过验证")
            return
        }
        let storeURL = URL(fileURLWithPath: realStorePath)
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let nodes = try decoder.decode([ProxyNode].self, from: data)

        let withCredentials = nodes.filter { $0.outboundJSON != nil }.count
        print("真实节点: \(nodes.count)，有完整凭证: \(withCredentials)")
        #expect(withCredentials == nodes.count, "所有节点必须有完整凭证")

        let config = try ConfigBuilder.data(nodes: nodes, apiPort: 19090, mixedPort: 17890)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-real-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let configURL = tmpDir.appendingPathComponent("config.json")
        try config.write(to: configURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/spike/sing-box")
        process.arguments = ["check", "-c", configURL.path, "-D", tmpDir.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        if process.terminationReason != .exit || process.terminationStatus != 0 {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Issue.record("sing-box check 失败: \(errText)")
        } else {
            print("sing-box check 通过 ✓")
        }

        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 端到端：真实配置启动 sing-box → 经混合端口访问外网 → 关闭。
    /// 这是"凭证真实有效"的最终证据 —— sing-box check 只验证 schema，
    /// 不验证密码对不对、服务器连不连得上。
    @Test("端到端：真实节点走通隧道")
    func realEndToEnd() async throws {
        guard FileManager.default.fileExists(atPath: realStorePath) else {
            print("未找到真实订阅 store，跳过端到端")
            return
        }
        let storeURL = URL(fileURLWithPath: realStorePath)
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let nodes = try decoder.decode([ProxyNode].self, from: data)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let configURL = workDir.appendingPathComponent("config.json")
        try ConfigBuilder.data(nodes: nodes, apiPort: 19090, mixedPort: 17890).write(to: configURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/spike/sing-box")
        process.arguments = ["run", "-c", configURL.path, "-D", workDir.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        defer { process.terminate() }

        // 等 API 就绪（最多 10 秒）
        var ready = false
        for _ in 0..<50 where !ready {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let _ = try? await getURL("http://127.0.0.1:19090/version") { ready = true }
        }
        #expect(ready, "sing-box 应在 10 秒内就绪")
        guard ready else { return }

        // 经混合端口访问 Cloudflare 的 204 探测点（走默认选中的第一个节点）
        // 用 first 节点可能被机场封 IP，失败时不硬报错，打印出来人工判断
        do {
            let proxyConfig = URLSessionConfiguration.default
            proxyConfig.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: 17890,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: 17890,
            ]
            let session = URLSession(configuration: proxyConfig)
            var req = URLRequest(url: URL(string: "http://cp.cloudflare.com/generate_204")!)
            req.timeoutInterval = 15
            let (_, response) = try await session.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("经隧道访问 cp.cloudflare.com: HTTP \(code)")
            #expect(code == 204, "隧道应能出网（204）")
        } catch {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let log = String(data: errData, encoding: .utf8) ?? ""
            // 打印 sing-box 日志尾部辅助诊断（不含凭证）
            let tail = log.components(separatedBy: .newlines).suffix(8).joined(separator: "\n")
            print("隧道访问失败，sing-box 日志尾部:\n\(tail)")
            Issue.record("经隧道出网失败: \(error.localizedDescription)")
        }

        func getURL(_ urlString: String) async throws -> Data {
            try await withCheckedThrowingContinuation { cont in
                URLSession.shared.dataTask(with: URL(string: urlString)!) { d, _, e in
                    if let e { cont.resume(throwing: e) } else if let d { cont.resume(returning: d) }
                    else { cont.resume(throwing: URLError(.badServerResponse)) }
                }.resume()
            }
        }
    }
}
