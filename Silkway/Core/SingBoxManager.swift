import Foundation
import Observation

/// sing-box 进程管理器，唯一状态源。
///
/// 职责（对应手册 3.2 生命周期）：
///   1. 动态分配端口
///   2. 调 ConfigBuilder 生成配置并写入磁盘
///   3. 用 Process 拉起 sing-box 子进程
///   4. 轮询 Clash API 确认就绪
///   5. 启动后开系统代理，退出/崩溃时关系统代理
///
/// 技术验证（任务 0）已证实的关键事实：
///   - Process() 以普通用户身份即可拉起 sing-box（非 TUN 模式）
///   - Clash API 就绪约 200ms
///   - PUT /proxies/{group} 热切切换无需重启进程
///   - SIGTERM 后 sing-box 干净退出，端口释放
@Observable
@MainActor
final class SingBoxManager {

    static let shared = SingBoxManager()

    // MARK: - 状态（View 直接绑定）

    private(set) var isRunning = false
    private(set) var lastError: String?

    /// 当前路由模式（从内核同步，也可热切切换）。
    private(set) var mode: ProxyMode = .rule

    /// sing-box 报告的策略组（由 /proxies 解析而来）。
    private(set) var groups: [ProxyGroup] = []

    /// 测速结果，键为节点 tag（= sing-box outbound tag）。
    private(set) var latencyByTag: [String: LatencyResult] = [:]

    /// 批量测速进行中。
    private(set) var isTestingLatency = false
    private(set) var latencyTestProgress: Double = 0

    /// 连接时间，供菜单栏显示运行时长。
    private(set) var startTime: Date?

    /// 当前分配的实际端口。SystemProxy 和 SingBoxAPIClient 都从这里取。
    private(set) var currentMixedPort: UInt16 = 0
    private(set) var currentAPIPort: UInt16 = 0

    // MARK: - 内部

    /// sing-box 二进制路径。App 里指向 Bundle 内嵌资源；测试时注入 spike 路径。
    var singBoxBinaryURL: URL = Bundle.main.url(forResource: "sing-box", withExtension: nil)
        ?? URL(fileURLWithPath: "/Users/kevinwang/vibeCoding/Silkway/spike/sing-box")

    /// 系统代理抽象。默认是真实 SystemProxy；测试注入 mock 避免改本机设置。
    var systemProxy: any SystemProxyManaging = SystemProxy.shared

    private var process: Process?
    private var apiClient: SingBoxAPIClient?
    private var pollingTask: Task<Void, Never>?

    /// 工作目录：config.json / cache.db / sing-box.log 都放这里。
    /// var 而非 let：测试注入临时目录，避免与运行中的 App 抢同一把
    /// cache.db 文件锁（flock 冲突会让 sing-box 启动超时），
    /// 也避免测试覆盖 App 的真实 config.json。
    var appSupportDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Silkway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 节点来源。默认从 SubscriptionManager 取；测试注入空数组，
    /// 让生成的 selector 只含 direct-out，与环境里有没有真实订阅无关。
    var nodeProvider: () -> [ProxyNode] = { SubscriptionManager.shared.allNodes }

    /// 当前生效的完整配置来源。默认读 AppConfig.activeProfileID → ProfileStore；
    /// 测试注入固定 profile 或 nil（节点模式）。
    var profileProvider: () -> ImportedProfile? = {
        guard let id = AppConfigStore.shared.config.activeProfileID else { return nil }
        return ProfileStore.shared.profile(id: id)
    }

    /// 应用配置来源。默认从 AppConfigStore 取（持久化的用户设置）；
    /// 测试注入固定配置，避免读写真实磁盘。
    var configProvider: () -> AppConfig = { AppConfigStore.shared.config }

    private init() {}

    // MARK: - 生命周期

    func toggle() {
        if isRunning {
            Task { await stop() }
        } else {
            Task { try? await start() }
        }
    }

    /// TUN 模式下 daemon 的 API 端口（写入 tun-config.json，主 App 靠它连 Clash API）。
    private(set) var tunAPIPort: UInt16 = 0

    /// 当前是否为 TUN 模式运行（sing-box 是 launchd daemon，非子进程）。
    private(set) var isTunMode = false

    func start() async throws {
        guard !isRunning else { return }

        let appConfig = configProvider()

        if appConfig.tunEnabled {
            try await startTUN(config: appConfig)
        } else {
            try await startLocal(config: appConfig)
        }
    }

    /// TUN 模式启动：配置写共享目录 → 注册 daemon → 轮询 API。
    /// 不碰系统代理（TUN 接管全部流量），不持有子进程句柄。
    private func startTUN(config: AppConfig) async throws {
        let tun = TunManager.shared

        // TUN 只在 /Applications 下可用（plist 里写死了绝对路径）
        guard tun.isAvailable else {
            lastError = "TUN 模式需要先把 Silkway.app 放入 /Applications"
            throw SingBoxError.tunNotAvailable
        }

        let apiPort = PortAllocator.allocate()
        tunAPIPort = apiPort
        _ = try tun.writeConfig(
            nodes: nodeProvider(), config: config,
            apiPort: apiPort, mixedPort: 0,
            profile: profileProvider()
        )

        // 注册前如果已注册，先注销确保用新配置
        if tun.isRegistered {
            try await tun.unregister()
        }
        try tun.register()

        // daemon 拉起 sing-box 需要时间；同时用户可能要去系统设置批准
        let client = SingBoxAPIClient(baseURL: URL(string: "http://127.0.0.1:\(apiPort)")!)
        let ready = await waitForReady(client: client, timeout: .seconds(15))
        guard ready else {
            // 把 daemon 真实状态带进错误，否则只看到"超时"无法定位
            let statusText: String
            switch tun.status {
            case .notRegistered:    statusText = "未注册"
            case .enabled:          statusText = "已注册但进程未起"
            case .requiresApproval: statusText = "等待用户批准"
            case .notFound:         statusText = "plist 未找到"
            @unknown default:       statusText = "未知(\(tun.status.rawValue))"
            }

            if tun.status == .requiresApproval {
                lastError = "请在系统设置 → 通用 → 登录项与扩展中批准 Silkway，然后重试"
                tun.openSystemSettings()
            } else {
                lastError = "TUN daemon 启动失败（状态：\(statusText)）。日志：/Users/Shared/Silkway/tun-daemon.log"
            }
            throw SingBoxError.apiNotReady
        }

        apiClient = client
        isRunning = true
        isTunMode = true
        startTime = Date()
        lastError = nil
        await refreshGroups()
        startPolling()
    }

    /// 本地模式启动（系统代理）：子进程 + networksetup。原有逻辑。
    private func startLocal(config: AppConfig) async throws {
        // 1. 分配端口（固定端口会撞其他 Clash 客户端，见手册 7.4）
        currentMixedPort = PortAllocator.allocate()
        currentAPIPort = PortAllocator.allocate()

        // 2. 生成配置并写盘
        let configURL = try buildConfig()

        // 3. 回收上次会话残留的孤儿 sing-box（防 cache.db 文件锁冲突）
        await killOrphanedProcessIfAny()

        // 4. 拉起进程
        do {
            try startProcess(configURL: configURL)
        } catch {
            // 进程都起不来（二进制缺失/权限），错误必须落到 lastError 让 UI 显示
            lastError = "无法启动 sing-box：\(error.localizedDescription)"
            throw error
        }

        // 5. 轮询 API 就绪
        let client = SingBoxAPIClient(baseURL: URL(string: "http://127.0.0.1:\(currentAPIPort)")!)
        let ready = await waitForReady(client: client, timeout: .seconds(5))
        guard ready else {
            stopProcess()
            lastError = "sing-box 启动后 5 秒内 Clash API 未就绪"
            throw SingBoxError.apiNotReady
        }
        apiClient = client
        isRunning = true
        startTime = Date()
        // 启动成功 → 清掉之前残留的错误状态，否则 UI 会一直显示旧错误
        lastError = nil

        // 拉取策略组与模式
        await refreshGroups()

        // 接管系统代理
        do {
            try await systemProxy.enable(host: "127.0.0.1", port: Int(currentMixedPort))
        } catch {
            // 代理设置失败必须让用户知道 —— 否则「以为在代理实际裸奔」
            lastError = "系统代理设置失败：\(error.localizedDescription)"
        }

        startPolling()
    }

    /// 停止 sing-box 并清理。
    ///
    /// 必须等待进程真正退出 + 系统代理关闭后才返回，
    /// 否则调用方（包括测试）立即检查端口/代理状态会竞态失败。
    func stop() async {
        stopPolling()

        // 先置状态再 terminate —— handleTermination 靠 isRunning 区分
        // 「主动停止」和「异常退出」。顺序不能反，否则清理会跑两遍。
        isRunning = false
        apiClient = nil

        // TUN 模式：注销 daemon，launchd 会终止 root 态 sing-box
        if isTunMode {
            isTunMode = false
            try? await TunManager.shared.unregister()
            startTime = nil
            return
        }

        // 等进程退出（最多 2 秒），避免端口检查和代理清理的竞态
        if let process {
            process.terminate()
            let deadline = ContinuousClock.now + .seconds(2)
            while process.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        stopProcess()

        await systemProxy.disable()
        startTime = nil
    }

    // MARK: - 策略组与模式

    /// 从内核刷新策略组列表和当前模式。
    func refreshGroups() async {
        guard let client = apiClient, isRunning else { return }
        do {
            let proxies = try await client.proxies()
            groups = proxies
                .compactMap { _, info -> ProxyGroup? in
                    guard let type = GroupType.fromClashType(info.type) else { return nil }
                    return ProxyGroup(
                        name: info.name,
                        type: type,
                        tag: badgeTag(for: info.name),
                        memberTags: info.all ?? [],
                        selectedTag: info.now
                    )
                }
                .sorted { $0.name < $1.name }

            if let modeRaw = try? await client.configs(),
               let synced = ProxyMode(rawValue: modeRaw) {
                mode = synced
            }
        } catch {
            lastError = "刷新策略组失败"
        }
    }

    /// 热切切换路由模式（global / rule / direct）。
    func setMode(_ newMode: ProxyMode) async {
        guard let client = apiClient, isRunning else {
            // 未运行时先记下偏好，UI 立即反馈，下次启动生效
            mode = newMode
            return
        }
        do {
            try await client.setMode(newMode)
            mode = newMode
        } catch {
            lastError = "切换模式失败：\(error.localizedDescription)"
        }
    }

    /// 组徽标：取组名前两个字符大写。设计稿里组有自定义两字母角标（AD/AI/DV），
    /// 那些来自机场自己的配置；我们自己生成的组只能派生。
    private func badgeTag(for name: String) -> String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(2)).uppercased()
    }

    // MARK: - 批量测速

    /// 批量测量所有组内节点的延迟，限并发（手册 6.4）。
    ///
    /// 结果逐个写入 latencyByTag，UI 即时刷新数字和颜色 ——
    /// 这是设计稿明确要求的交互（「完成后延迟数字逐个刷新并重新着色」）。
    func testLatency() async {
        guard let client = apiClient, isRunning, !isTestingLatency else { return }

        // 去重：一个节点可能出现在多个组里
        var seen = Set<String>()
        let targets = groups.flatMap(\.memberTags).filter { seen.insert($0).inserted }
        guard !targets.isEmpty else { return }

        isTestingLatency = true
        latencyTestProgress = 0
        defer { isTestingLatency = false }

        let chunkSize = 10
        var completed = 0
        var index = targets.startIndex

        while index < targets.endIndex {
            let end = targets.index(index, offsetBy: chunkSize, limitedBy: targets.endIndex) ?? targets.endIndex
            let chunk = targets[index..<end]

            await withTaskGroup(of: (String, LatencyResult).self) { taskGroup in
                for tag in chunk {
                    taskGroup.addTask {
                        if let ms = try? await client.delay(proxy: tag) {
                            return (tag, .value(ms))
                        }
                        return (tag, .timeout)
                    }
                }
                for await (tag, result) in taskGroup {
                    latencyByTag[tag] = result
                    completed += 1
                    latencyTestProgress = Double(completed) / Double(targets.count)

                    // 同时回写到持久化存储（按节点名匹配 tag，重启后延迟徽章仍在）
                    if let node = SubscriptionManager.shared.allNodes.first(where: { $0.name == tag }) {
                        SubscriptionManager.shared.recordLatency(nodeID: node.id, result: result)
                    }
                }
            }
            index = end
        }
    }

    func restart() async throws {
        await stop()
        try await start()
    }

    /// 生成新配置并热重载内核（不重启进程）。
    ///
    /// 订阅更新、节点增删后调用。走 `PUT /configs?path=…` 热重载，
    /// 比 stop+start 快（保持系统代理状态、端口不变、活跃连接尽量延续）。
    /// 未运行时是 no-op（下次 start 自然会用新配置）。
    func reloadConfigIfRunning() async {
        guard isRunning, apiClient != nil else { return }
        do {
            // TUN 模式重写共享配置（daemon 读的那份）；本地模式重写 appSupportDir
            let url: URL
            if isTunMode {
                url = try TunManager.shared.writeConfig(
                    nodes: nodeProvider(), config: configProvider(),
                    apiPort: tunAPIPort, mixedPort: 0
                )
            } else {
                url = try buildConfig()
            }
            try await apiClient?.reloadConfig(path: url.path)
            // 热重载后内核的组/模式可能重置，重新同步
            await refreshGroups()
            lastError = nil
        } catch {
            // 热重载失败不致命 —— 旧配置仍在跑，记个错即可
            lastError = "配置热重载失败，继续使用旧配置：\(error.localizedDescription)"
        }
    }

    // MARK: - 节点切换

    /// 通过 Clash API 热切切换策略组选中节点。
    ///
    /// 当前实现直接用 tag 而非 UUID —— sing-box 配置里的 tag 就是唯一标识，
    /// UUID 到 tag 的映射由上层（持有 ProxyGroup 的 Store）提供。
    /// 这里接受 tag 是为了与内核的标识系统对齐，避免双重映射。
    func switchNode(groupTag: String, nodeTag: String) async throws {
        guard let client = apiClient, isRunning else {
            throw SingBoxError.notRunning
        }
        try await client.switchProxy(groupTag: groupTag, to: nodeTag)
    }

    // MARK: - 配置与进程

    private func buildConfig() throws -> URL {
        let nodes = nodeProvider()
        let config = configProvider()
        let profile = profileProvider()
        // 绕过大陆开启时注入规则集（未下载时为空数组，规则自然不生效）
        let ruleSets = config.bypassChinaMainland ? RuleSetManager.shared.ruleSetConfig() : []
        let data = try ConfigBuilder.data(
            nodes: nodes,
            config: config,
            apiPort: currentAPIPort,
            mixedPort: currentMixedPort,
            profile: profile,
            ruleSets: ruleSets
        )
        let url = appSupportDir.appendingPathComponent("config.json")
        try data.write(to: url)
        return url
    }

    /// pid 文件路径。记录 sing-box 进程号，供下次启动时清理孤儿进程。
    private var pidFileURL: URL { appSupportDir.appendingPathComponent("sing-box.pid") }

    /// 杀掉上次会话残留的 sing-box 孤儿进程。
    ///
    /// App 崩溃/强制退出/调试器终止时，terminationHandler 不会跑，
    /// sing-box 子进程变成孤儿继续占着端口和 cache.db 文件锁，
    /// 导致下次启动 FATAL "initialize cache-file: timeout"。
    /// 启动前必须先回收。优先用 pid 文件精确回收；
    /// pid 文件缺失（升级前版本、手动删除）时按命令行特征兜底扫描。
    private func killOrphanedProcessIfAny() async {
        var killedAny = false

        // 路径 A：pid 文件 → 精确回收
        if let pidString = try? String(contentsOf: pidFileURL, encoding: .utf8),
           let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)),
           processMatchesOurs(pid: pid) {
            kill(pid, SIGTERM)
            killedAny = true
        }
        try? FileManager.default.removeItem(at: pidFileURL)

        // 路径 B：无 pid 文件时，扫描所有 sing-box 进程，
        // 命令行含我们的工作目录（-D <appSupportDir>）的才杀。
        // pgrep -f 匹配完整命令行，不会碰到其他用户/其他 App 的 sing-box。
        let scan = Process()
        scan.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        scan.arguments = ["-f", "sing-box.*-D \(appSupportDir.path)"]
        let pipe = Pipe()
        scan.standardOutput = pipe
        scan.standardError = Pipe()  // 无匹配时 pgrep 返回 1 是正常，不视为错误
        try? scan.run()
        scan.waitUntilExit()
        let pids = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in pids.components(separatedBy: .newlines) where !line.isEmpty {
            if let pid = Int32(line), pid != process?.processIdentifier {
                Foundation.kill(pid, SIGTERM)
                killedAny = true
            }
        }

        // 等 flock 释放（async sleep，不阻塞主线程）
        if killedAny {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// 核对 pid 是否真的是我们拉起的 sing-box（防 pid 复用误杀）。
    private func processMatchesOurs(pid: Int32) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        check.standardOutput = pipe
        try? check.run()
        check.waitUntilExit()
        let cmdline = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return cmdline.contains("sing-box") && cmdline.contains(appSupportDir.path)
    }

    private func writePidFile(_ pid: Int32) {
        try? String(pid).write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func startProcess(configURL: URL) throws {
        let workDir = appSupportDir
        let process = Process()
        process.executableURL = singBoxBinaryURL
        process.arguments = ["run", "-c", configURL.path, "-D", workDir.path]

        process.terminationHandler = { [weak self] p in
            // 回调在非主线程 —— 必须 hop 到 MainActor
            Task { @MainActor in
                self?.handleTermination(p)
            }
        }

        try process.run()
        self.process = process
        writePidFile(process.processIdentifier)
    }

    private func stopProcess() {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// 进程非正常退出（崩溃 / 被 kill）时同步状态。
    ///
    /// 手册 9 已知陷阱：「忘记处理 sing-box 崩溃 → 应用状态与实际不一致」。
    private func handleTermination(_ p: Process) {
        // 主动 stop() 时已先处理过状态；这里收到回调且 isRunning 仍为 true，
        // 说明是异常退出。
        guard isRunning else { return }

        isRunning = false
        apiClient = nil
        stopPolling()
        Task { await systemProxy.disable() }

        if p.terminationReason == .exit, p.terminationStatus != 0 {
            lastError = "sing-box 异常退出（code \(p.terminationStatus)）"
        } else if p.terminationReason == .uncaughtSignal {
            lastError = "sing-box 被信号终止（崩溃？）"
        }
    }

    // MARK: - 就绪探测

    private func waitForReady(client: SingBoxAPIClient, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let _ = try? await client.version() {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return false
    }

    /// 把 API 的 ConnectionInfo 映射为内部 Connection 模型。
    ///
    /// 内核的 start 字段是 RFC3339（如 2024-01-15T08:30:00.123Z），
    /// 解析失败就用当前时间兜底（时长显示为 0，不影响列表）。
    private static func mapConnection(_ info: SingBoxAPIClient.ConnectionInfo) -> Connection {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = info.start.flatMap { formatter.date(from: $0) }
            ?? ISO8601DateFormatter().date(from: info.start ?? "")
            ?? Date()

        let metadata = info.metadata
        // 目标显示优先级：域名 > 目的 IP。端口可能缺失（如 unix socket）。
        let host = metadata?.host ?? metadata?.destinationIP ?? "未知"
        let port = Int(metadata?.destinationPort ?? "") ?? 0

        return Connection(
            id: info.id,
            host: host,
            destinationPort: port,
            network: metadata?.network ?? "TCP",
            rule: info.rule ?? "",
            rulePayload: info.rulePayload,
            chains: info.chains,
            uploadBytes: info.upload,
            downloadBytes: info.download,
            startTime: start
        )
    }

    // MARK: - 流量轮询

    /// 上一次 /connections 的累计总量，用于差值算速率。
    private var lastTotals: (up: Int64, down: Int64)?

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // 用 /connections 总量差值算速率，不用 /traffic ——
                // 后者是 WebSocket 流式端点，URLSession.data(for:) 会永久挂起。
                if let client = self.apiClient,
                   let conns = try? await client.connections() {
                    if let last = self.lastTotals {
                        let upRate = max(0, conns.uploadTotal - last.up)
                        let downRate = max(0, conns.downloadTotal - last.down)
                        self.lastTraffic = TrafficSample(up: upRate, down: downRate, at: Date())
                        // 追加到历史，裁剪到上限
                        self.trafficHistory.append(self.lastTraffic!)
                        if self.trafficHistory.count > self.trafficHistoryLimit {
                            self.trafficHistory.removeFirst(self.trafficHistory.count - self.trafficHistoryLimit)
                        }
                    }
                    self.lastTotals = (conns.uploadTotal, conns.downloadTotal)
                    self.connections = (conns.connections ?? []).map(Self.mapConnection)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 最近一次拉到的流量快照。菜单栏速率显示从这里读。
    private(set) var lastTraffic: TrafficSample?

    /// 当前活跃连接列表。连接日志页从这里读。
    private(set) var connections: [Connection] = []

    /// 流量历史（每秒一个样本，最多保留 60 个 = 1 分钟），给流量图用。
    private(set) var trafficHistory: [TrafficSample] = []

    /// 流量图最多保留的样本数。
    private let trafficHistoryLimit = 60

    struct TrafficSample: Sendable, Identifiable {
        let id = UUID()
        let up: Int64      // bytes/s
        let down: Int64    // bytes/s
        let at: Date
    }

    /// 断开一条活跃连接。
    func closeConnection(id: String) async {
        guard let client = apiClient else { return }
        try? await client.closeConnection(id: id)
        // 下一次轮询会刷新列表；这里本地立即移除，反馈更快。
        connections.removeAll { $0.id == id }
    }
}

// MARK: - 系统代理抽象

/// 抽象系统代理操作，便于测试替换。
protocol SystemProxyManaging: Sendable {
    func enable(host: String, port: Int) async throws
    func disable() async
}

extension SystemProxy: SystemProxyManaging {}

// MARK: - 错误

enum SingBoxError: Error, CustomStringConvertible {
    case apiNotReady
    case notRunning
    case tunNotAvailable
    case processLaunchFailed(String)

    var description: String {
        switch self {
        case .apiNotReady: return "sing-box 启动超时"
        case .notRunning:  return "sing-box 未运行"
        case .tunNotAvailable: return "TUN 模式需要 App 位于 /Applications"
        case .processLaunchFailed(let msg): return "无法启动 sing-box：\(msg)"
        }
    }
}
