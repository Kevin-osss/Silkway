import Foundation

/// 端口探测。
///
/// 固定端口会与用户已装的其他 Clash 客户端冲突（实测 9090 被 ClashMac 占用，
/// 且 lsof 非 root 看不到占用者）。所以默认动态分配。
enum PortAllocator {

    /// 分配一个空闲的本地端口。
    ///
    /// 实现：bind 到端口 0，由内核分配，然后立即关闭。
    /// 注意：存在极小的竞争窗口（端口释放后被别人抢走），但概率极低，
    /// 且 sing-box 启动失败时 SingBoxManager 会捕获并提示用户重试。
    static func allocate() -> UInt16 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return fallback() }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return fallback() }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var result = addr
        let getResult = withUnsafeMutablePointer(to: &result) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard getResult == 0 else { return fallback() }

        return UInt16(bigEndian: result.sin_port)
    }

    /// socket 失败时的兜底：返回高位随机端口，交给 sing-box 自己报错。
    private static func fallback() -> UInt16 {
        UInt16.random(in: 40000...60000)
    }
}
