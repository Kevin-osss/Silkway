import Foundation
import Testing
@testable import SilkwayCore

/// 本地文件导入的端到端测试。
///
/// 覆盖两级解析路径：
///   1. 含策略组/规则 → ImportedProfile
///   2. 纯节点 → 手动节点
/// 以及同名查重和不支持格式的错误处理。
@Suite("本地文件导入")
@MainActor
struct LocalFileImportTests {

    /// 临时文件写入辅助。
    /// 文件名不带 UUID（保持用户真实导入的行为：精确同名查重），
    /// 测试间通过清理 profiles.json 避免状态污染。
    private func writeTemp(_ text: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).yaml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 清理指定 name 的配置（测试间避免状态污染）
    private func removeProfilesWithName(_ name: String) {
        ProfileStore.shared.allProfiles
            .filter { $0.name == name }
            .forEach { ProfileStore.shared.removeProfile(id: $0.id) }
    }

    @Test("Clash YAML 含策略组 → 导入为完整配置")
    func importClashYAMLWithGroups() async throws {
        let yaml = """
        proxies:
          - {name: 香港01, type: ss, server: hk.example.com, port: 8388, cipher: aes-256-gcm, password: pw}
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - 香港01
        rules:
          - DOMAIN-SUFFIX,google.com,PROXY
          - MATCH,PROXY
        """
        let url = try writeTemp(yaml, name: "测试配置")

        let manager = SubscriptionManager()
        let result = try await manager.importLocalFile(url: url)

        #expect(result.contains("已导入完整配置"))
        #expect(result.contains("1 个策略组"))

        // 验证 profile 已存入
        let profile = ProfileStore.shared.allProfiles.first { $0.name == "测试配置" }
        #expect(profile != nil)
        #expect(profile?.proxyGroups.count == 1)
        #expect(profile?.proxyGroups.first?.name == "PROXY")

        try? FileManager.default.removeItem(at: url)
        removeProfilesWithName("测试配置")
    }

    @Test("同名配置重复导入 → 覆盖而不是增生")
    func importSameNameTwice() async throws {
        let yaml = """
        proxies:
          - {name: 节点A, type: ss, server: a.com, port: 8388, cipher: aes-256-gcm, password: pw}
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - 节点A
        """
        let url = try writeTemp(yaml, name: "重复配置")
        let manager = SubscriptionManager()

        let r1 = try await manager.importLocalFile(url: url)
        #expect(r1.contains("已导入"))

        let r2 = try await manager.importLocalFile(url: url)
        #expect(r2.contains("已更新"))

        // 同名配置只有一份
        let count = ProfileStore.shared.allProfiles.filter { $0.name.hasPrefix("重复配置") }.count
        #expect(count == 1)

        removeProfilesWithName("重复配置")
        try? FileManager.default.removeItem(at: url)
    }

    @Test("纯节点文件 → 导入为手动节点")
    func importNodesOnly() async throws {
        let text = """
        ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@ss.example.com:8388#SS节点
        vless://11111111-2222-3333-4444-555555555555@v.example.com:443?security=tls&sni=v.example.com&type=ws&path=%2Fws#VLESS节点
        """
        let url = try writeTemp(text, name: "纯节点")
        let manager = SubscriptionManager()

        let result = try await manager.importLocalFile(url: url)

        #expect(result.contains("已导入 2 个手动节点"))

        // 手动节点（subscriptionID = nil）已存入
        let manualNodes = ProxyNodeStore.shared.allNodes.filter { $0.subscriptionID == nil }
        #expect(manualNodes.count >= 2)

        try? FileManager.default.removeItem(at: url)
    }

    @Test("不支持的格式 → 报错")
    func importUnsupported() async throws {
        let url = try writeTemp("这不是任何支持的格式", name: "无效")
        let manager = SubscriptionManager()

        do {
            _ = try await manager.importLocalFile(url: url)
            Issue.record("应抛出 unsupportedFormat 错误")
        } catch let error as SubscriptionError {
            #expect(error == .unsupportedFormat)
        }

        try? FileManager.default.removeItem(at: url)
    }

    @Test("sing-box 完整配置 → 直通保留 route.rules")
    func importSingBoxConfig() async throws {
        let json = """
        {
          "outbounds": [
            {"type": "selector", "tag": "PROXY", "outbounds": ["n1"], "default": "n1"},
            {"type": "shadowsocks", "tag": "n1", "server": "a.com", "server_port": 8388, "method": "aes-256-gcm", "password": "pw"},
            {"type": "direct", "tag": "direct-out"}
          ],
          "route": {
            "rules": [{"domain_suffix": ["cn"], "outbound": "direct-out"}],
            "final": "PROXY"
          }
        }
        """
        let url = try writeTemp(json, name: "sing-box配置")
        let manager = SubscriptionManager()

        let result = try await manager.importLocalFile(url: url)

        #expect(result.contains("已导入完整配置"))

        let profile = ProfileStore.shared.allProfiles.first { $0.name == "sing-box配置" }
        #expect(profile?.rules.count == 1, "route.rules 应原样保留")

        removeProfilesWithName("sing-box配置")
        try? FileManager.default.removeItem(at: url)
    }
}
