import Foundation

/// 封装 macOS 系统代理设置。
///
/// sing-box 启动后只监听本地端口，系统默认不会把流量导向它。
/// 本服务通过调用 `/usr/sbin/networksetup` 把 HTTP / HTTPS / SOCKS 代理
/// 指向 sing-box 的 mixed 入站端口。
///
/// 注意：
///   - 设置当前用户的网络配置不需要 root（与 TUN 模式不同）
///   - 必须对所有**活跃**的网络服务都设置，否则切到以太网会漏流量
///   - App 退出或崩溃前必须调用 `disable()`，否则用户断网
public actor SystemProxy {

    public static let shared = SystemProxy()

    private let binary = "/usr/sbin/networksetup"

    /// 最后一次 enable 时操作过的服务。
    ///
    /// App 生命周期代码（AppDelegate）在收到 `NSApplication.willTerminateNotification`
    /// 时应调用 `SystemProxy.disable()`，这里不自己注册 atexit，
    /// 因为 C atexit 不能捕获 Swift actor 上下文。
    private var lastEnabledServices: [String] = []

    private init() {}

    // MARK: - 错误类型

    public enum Error: Swift.Error, CustomStringConvertible {
        case listServicesFailed(String)
        case commandFailed(command: String, detail: String)

        public var description: String {
            switch self {
            case .listServicesFailed(let msg):
                return "无法读取网络服务列表：\(msg)"
            case .commandFailed(let command, let detail):
                return "命令 networksetup \(command) 失败：\(detail)"
            }
        }
    }

    // MARK: - 公开 API

    /// 为所有活跃网络服务启用系统代理。
    ///
    /// - Parameters:
    ///   - host: 代理服务器地址，通常是 `127.0.0.1`
    ///   - port: sing-box mixed 入站端口
    public func enable(host: String = "127.0.0.1", port: Int) async throws {
        let services = try await activeServices()
        lastEnabledServices = services

        for service in services {
            try await setProxyState(service: service, enabled: true, host: host, port: port)
        }
    }

    /// 关闭所有曾开启过的网络服务的系统代理。
    ///
    /// 使用 `lastEnabledServices` 而非重新扫描，是因为服务列表可能变化
    /// （如用户切换了 Wi-Fi），但我们只对自己动过的服务负责。
    public func disable() async {
        for service in lastEnabledServices {
            try? await setProxyState(service: service, enabled: false, host: "127.0.0.1", port: 0)
        }
        lastEnabledServices.removeAll()
    }

    // MARK: - 查询（用于 UI 状态同步）

    /// 返回指定服务的当前 HTTP 代理状态。
    public func httpProxyState(service: String) async -> (enabled: Bool, host: String?, port: Int?) {
        let output = try? await run(["-getwebproxy", service])
        return Self.parseProxyState(output ?? "")
    }

    // MARK: - 内部实现

    /// 解析 `networksetup -getwebproxy <service>` 的输出。
    ///
    /// 典型格式：
    ///   Enabled: Yes
    ///   Server: 127.0.0.1
    ///   Port: 2080
    static func parseProxyState(_ output: String) -> (enabled: Bool, host: String?, port: Int?) {
        var enabled = false
        var host: String?
        var port: Int?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "enabled":  enabled = value.lowercased() == "yes"
            case "server":   host = value
            case "port":     port = Int(value)
            default:          break
            }
        }
        return (enabled, host, port)
    }

    /// 获取所有**非禁用**的网络服务名。
    ///
    /// `networksetup -listallnetworkservices` 的输出：
    ///
    ///     An asterisk (*) denotes that a network service is disabled.
    ///     (null)
    ///     Wi-Fi
    ///     *Bluetooth PAN
    ///
    /// 第一行是说明，`(null)` 是占位服务名要跳过，带 `*` 的是已禁用。
    func activeServices() async throws -> [String] {
        let output = try await run(["-listallnetworkservices"])
        return try Self.parseServiceList(output)
    }

    /// 解析 `-listallnetworkservices` 的 stdout。
    /// 抽成纯函数是为了可测 —— 曾经的测试只验证了 hasPrefix("*")，
    /// 根本没走到解析逻辑，stdout/stderr 读反的 bug 因此漏网。
    static func parseServiceList(_ output: String) throws -> [String] {
        var lines = output.split(separator: "\n").map { String($0) }
        guard !lines.isEmpty else { throw Error.listServicesFailed("输出为空") }

        // 第一行是固定提示语，不是服务
        lines.removeFirst()

        return lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳过禁用服务和空行/占位行
            if trimmed.isEmpty || trimmed == "(null)" || trimmed.hasPrefix("*") {
                return nil
            }
            return trimmed
        }
    }

    /// 对某个服务设置三类代理的开关。
    func setProxyState(service: String, enabled: Bool, host: String, port: Int) async throws {
        // networksetup 三类代理：HTTP / HTTPS / SOCKS
        let commands: [[String]] = [
            [enabled ? "-setwebproxy"        : "-setwebproxystate", service] + (enabled ? [host, String(port)] : ["Off"]),
            [enabled ? "-setsecurewebproxy"  : "-setsecurewebproxystate", service] + (enabled ? [host, String(port)] : ["Off"]),
            [enabled ? "-setsocksfirewallproxy" : "-setsocksfirewallproxystate", service] + (enabled ? [host, String(port)] : ["Off"])
        ]

        for args in commands {
            _ = try await run(args)  // exit code ≠ 0 时 run() 自动抛错
        }
    }

    /// 执行 networksetup 并返回 stdout。
    ///
    /// ⚠️ networksetup 的数据输出（服务列表、代理状态）和错误信息都写在 **stdout**，
    /// stderr 永远是空的 —— 曾经误读 stderr 导致 activeServices 永远拿到空串，
    /// 系统代理从第一天起就没成功设置过（2026-09-03 真实 bug）。
    /// 正确判据：exit code ≠ 0 为失败，错误信息在 stdout。
    func run(_ args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            // 错误信息在 stdout（例如 "** Error: The parameters were not valid."）
            let detail = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.commandFailed(command: args.joined(separator: " "), detail: detail.isEmpty ? "exit code \(process.terminationStatus)" : detail)
        }
        return stdout
    }
}

// MARK: - 清理钩子

extension SystemProxy {

    /// 供应用终止时同步调用。由于 SystemProxy 是 actor，调用方需要：
    ///
    ///     Task { await SystemProxy.shared.disable() }
    ///
    /// 或者从 `willTerminateNotification` 的回调里 await。
    /// 注意：崩溃时不会执行；TUN 模式需要更健壮的清理（见第 8 节）。
    public func disableAndForget() async {
        await disable()
    }
}
