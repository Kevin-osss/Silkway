import Foundation
import Testing
@testable import SilkwayCore

/// ProxyNodeStore 持久化：新增/删除/替换后重新 init 应还原状态。
@Suite("ProxyNodeStore 持久化")
@MainActor
struct ProxyNodeStoreTests {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("silkway-store-test-\(UUID().uuidString)")
    }

    @Test("订阅和节点写入后可还原")
    func roundTrip() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProxyNodeStore(directory: dir)
        let sub = Subscription(name: "测试订阅", url: URL(string: "https://example.com/sub")!)
        store.addSubscription(sub)

        var node = ProxyNode(
            name: "香港 01", server: "hk.example.com", port: 443,
            proxyProtocol: .trojan, subscriptionID: sub.id
        )
        node.outboundJSON = #"{"type":"trojan","password":"pw"}"#
        store.replaceNodes(subscriptionID: sub.id, with: [node])

        // 重新 init（模拟重启），状态应从磁盘还原
        let reloaded = ProxyNodeStore(directory: dir)
        #expect(reloaded.subscriptions.count == 1)
        #expect(reloaded.subscriptions.first?.name == "测试订阅")
        #expect(reloaded.allNodes.count == 1)
        #expect(reloaded.allNodes.first?.name == "香港 01")
        #expect(reloaded.allNodes.first?.outboundJSON != nil)
        #expect(reloaded.nodes(for: sub.id).count == 1)
    }

    @Test("删除订阅同时删除其节点")
    func deleteCascades() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProxyNodeStore(directory: dir)
        let subA = Subscription(name: "A", url: URL(string: "https://a.example.com")!)
        let subB = Subscription(name: "B", url: URL(string: "https://b.example.com")!)
        store.addSubscription(subA)
        store.addSubscription(subB)
        store.replaceNodes(subscriptionID: subA.id, with: [
            ProxyNode(name: "A1", server: "a1.example.com", port: 443, proxyProtocol: .trojan, subscriptionID: subA.id),
        ])
        store.replaceNodes(subscriptionID: subB.id, with: [
            ProxyNode(name: "B1", server: "b1.example.com", port: 443, proxyProtocol: .trojan, subscriptionID: subB.id),
        ])

        store.removeSubscription(id: subA.id)

        let reloaded = ProxyNodeStore(directory: dir)
        #expect(reloaded.subscriptions.count == 1)
        #expect(reloaded.subscriptions.first?.name == "B")
        #expect(reloaded.allNodes.count == 1)
        #expect(reloaded.allNodes.first?.name == "B1")
    }

    @Test("replaceNodes 只影响目标订阅")
    func replaceIsScoped() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProxyNodeStore(directory: dir)
        let subA = Subscription(name: "A", url: URL(string: "https://a.example.com")!)
        let subB = Subscription(name: "B", url: URL(string: "https://b.example.com")!)
        store.addSubscription(subA)
        store.addSubscription(subB)
        store.replaceNodes(subscriptionID: subA.id, with: [
            ProxyNode(name: "A1", server: "s1", port: 1, proxyProtocol: .trojan, subscriptionID: subA.id),
            ProxyNode(name: "A2", server: "s2", port: 2, proxyProtocol: .trojan, subscriptionID: subA.id),
        ])
        store.replaceNodes(subscriptionID: subB.id, with: [
            ProxyNode(name: "B1", server: "s3", port: 3, proxyProtocol: .trojan, subscriptionID: subB.id),
        ])

        // 更新 A 后 B 不动
        store.replaceNodes(subscriptionID: subA.id, with: [
            ProxyNode(name: "A-new", server: "s4", port: 4, proxyProtocol: .trojan, subscriptionID: subA.id),
        ])

        #expect(store.nodes(for: subA.id).map(\.name) == ["A-new"])
        #expect(store.nodes(for: subB.id).map(\.name) == ["B1"])
    }

    @Test("空目录初始化为空状态")
    func emptyInit() {
        let store = ProxyNodeStore(directory: makeTempDir())
        #expect(store.subscriptions.isEmpty)
        #expect(store.allNodes.isEmpty)
    }
}
