# Silkway — AI Agent 项目协作手册

> 本文件面向所有参与 Silkway 开发的 AI Agent（Cursor、Claude、GPT 等）。
> 阅读本文件后，你应该能独立完成代码生成、重构、Bug 修复，无需额外上下文。

---

## 1. 项目概述（一句话）

**Silkway** 是一款基于 **sing-box** 内核的 macOS 原生代理客户端，纯菜单栏应用（无 Dock 图标），SwiftUI 开发，目标是为开发者提供简洁高效的代理工具。

### 技术栈

| 层级 | 技术 |
|------|------|
| 语言 | Swift 5.9+ |
| UI 框架 | SwiftUI（macOS 14+） |
| 架构模式 | MVVM + `@Observable`（SwiftData 可选） |
| 代理内核 | sing-box（Go 编写，以二进制嵌入） |
| 包管理 | Swift Package Manager |
| 设计规范 | Apple Human Interface Guidelines，深色优先 |

### 核心约束（不可违背）

1. **纯菜单栏应用**：`NSApp.setActivationPolicy(.accessory)`，无 Dock 图标
2. **无内置节点**：用户自行提供订阅链接或配置文件
3. **macOS 14+ 独占**：可使用最新 SwiftUI API，无需兼容旧系统
4. **GPL-3.0 协议**：sing-box 为 GPL-3.0，本项目代码也采用 GPL-3.0
5. **禁用 App Sandbox**：沙盒会阻断特权 Helper 与 `networksetup`，`com.apple.security.app-sandbox` 必须为 `false`（详见第 8 节）
6. **需 Apple 签名（开发即可，见第 8 节）**：特权 Helper 要求 App 经 Apple 证书签名。自用场景用 **Apple ID 免费登录 Xcode** 获得的 Apple Development 证书即可；仅当要把 App 分发给他人时才需要 $99/年的 Developer ID（公证是分发门槛，不是开发门槛）

---

## 2. 目录结构与职责

```
Silkway/
├── Silkway/
│   ├── App/
│   │   ├── SilkwayApp.swift          # @main 入口，注册 MenuBarExtra + Settings
│   │   └── AppDelegate.swift         # 应用生命周期，退出时清理 sing-box 进程
│   │
│   ├── Core/                         # 业务核心，所有 Agent 修改前必须阅读
│   │   ├── SingBoxManager.swift      # sing-box 进程管理（单例，@Observable）
│   │   ├── ConfigBuilder.swift       # 将订阅数据生成 sing-box JSON 配置
│   │   ├── SubscriptionManager.swift # 订阅拉取、解析、缓存
│   │   ├── ProxyNodeStore.swift      # 节点数据持久化（SwiftData / UserDefaults）
│   │   ├── SystemProxy.swift         # 系统代理设置（networksetup 命令封装）
│   │   └── HelperClient.swift        # 特权 Helper 的 XPC 客户端（注册/通信/版本校验）
│   │
│   ├── Models/                       # 数据模型，Codable + Identifiable
│   │   ├── ProxyNode.swift
│   │   ├── ProxyGroup.swift
│   │   ├── Subscription.swift
│   │   ├── Connection.swift
│   │   ├── AppConfig.swift
│   │   └── SingBoxConfig.swift       # 对应 sing-box 配置结构的 Swift 类型
│   │
│   ├── Services/                     # 独立服务，无 UI 依赖
│   │   ├── SpeedTestService.swift    # TCP ping / HTTP 延迟测速
│   │   ├── NetworkMonitor.swift      # 网络状态监听（WiFi/以太网切换）
│   │   ├── LogParser.swift           # 解析 sing-box 日志输出
│   │   └── SingBoxAPIClient.swift    # 与 sing-box REST API 通信（连接信息、切换节点）
│   │
│   ├── Views/
│   │   ├── MenuBar/                  # 菜单栏弹窗（宽度 340px）
│   │   │   ├── MenuBarView.swift     # 根容器
│   │   │   ├── StatusHeader.swift    # 开关 + 当前节点 + 模式选择
│   │   │   ├── GroupList.swift       # 策略组可折叠列表
│   │   │   ├── GroupRow.swift        # 单个策略组（DisclosureGroup）
│   │   │   ├── NodeRow.swift         # 单个节点行（国旗+名称+延迟+选中标记）
│   │   │   └── ActionFooter.swift    # 打开设置 / 退出
│   │   │
│   │   ├── Settings/                 # Settings 面板（TabView，minWidth 700）
│   │   │   ├── SettingsView.swift    # Tab 容器
│   │   │   ├── GeneralView.swift
│   │   │   ├── SubscriptionView.swift
│   │   │   ├── ProxyView.swift
│   │   │   ├── RuleView.swift
│   │   │   ├── DNSView.swift
│   │   │   ├── ConnectionView.swift
│   │   │   └── AboutView.swift
│   │   │
│   │   └── Components/               # 可复用组件
│   │       ├── LatencyBadge.swift    # 延迟颜色标签（绿/黄/红/灰）
│   │       ├── CountryFlag.swift     # 国家代码转 Emoji 国旗
│   │       ├── ProtocolTag.swift     # 协议类型小标签（SS/VLESS/Trojan...）
│   │       ├── TrafficChart.swift    # 流量折线图（SwiftUI Charts）
│   │       └── AnimatedToggle.swift  # 连接开关动画（脉冲光环）
│   │
│   ├── Utils/
│   │   ├── Constants.swift           # 颜色 Token、尺寸常量、SF Symbols 名称
│   │   ├── Formatters.swift          # ByteFormatter（B→KB→MB→GB）、DateFormatter
│   │   └── Extensions.swift          # Swift / SwiftUI 扩展
│   │
│   └── Resources/
│       ├── Assets.xcassets           # App Icon（Silkway 丝路 Logo）
│       └── sing-box                  # 嵌入的 sing-box 可执行文件（darwin-arm64/amd64）
│
├── SilkwayHelper/                    # 特权 Helper（独立 Target，以 root 运行）
│   ├── main.swift                    # NSXPCListener 入口
│   ├── HelperService.swift           # 实现 HelperProtocol，管理 root 态 sing-box 进程
│   ├── HelperProtocol.swift          # XPC 接口定义（主 App 与 Helper 共享此文件）
│   └── com.silkway.helper.plist      # LaunchDaemon 配置，构建后置入 Contents/Library/LaunchDaemons/
│
└── README.md
```

**Agent 编码规则**：
- 新增 View 必须放入 `Views/` 下对应子目录
- 新增业务逻辑必须放入 `Core/` 或 `Services/`，禁止在 View 中写网络请求或进程管理
- 所有数据模型必须 `Codable + Identifiable + Hashable`
- 所有管理类必须单例或 `@Observable`，状态变更驱动 UI 更新

---

## 3. 核心架构与数据流

### 3.1 状态管理

```
┌─────────────────┐
│  SingBoxManager │  ← 唯一状态源，@Observable
│   (单例)        │
└────────┬────────┘
         │ 发布状态变更
    ┌────┴────┐
    ▼         ▼
┌────────┐ ┌─────────────┐
│ Views  │ │ Services    │
│(SwiftUI)│ │(SpeedTest  │
└────────┘ │ APIClient)  │
           └─────────────┘
```

- **SingBoxManager** 是唯一的 `@Observable` 状态源
- View 直接读取 `SingBoxManager.shared`，不通过 EnvironmentObject
- 子 View 通过 `@State private var manager = SingBoxManager.shared` 引用

### 3.2 sing-box 生命周期

```
[用户点击开关]
    │
    ▼
[ConfigBuilder 生成 config.json]
    │
    ▼
[启动 sing-box 子进程: sing-box run -c config.json]
    │
    ▼
[SystemProxy 设置系统代理]
    │
    ▼
[SingBoxAPIClient 轮询连接状态 / 节点信息]
    │
    ▼
[用户切换节点 → 调用 sing-box API → 热重载配置]
```

### 3.3 关键类接口定义

以下接口是所有 Agent 必须遵守的契约，**修改前需同步更新本文档**。

```swift
// MARK: - SingBoxManager（核心单例）

@Observable
final class SingBoxManager {
    static let shared = SingBoxManager()

    // 状态属性（View 直接绑定）
    var isRunning: Bool = false
    var mode: ProxyMode = .rule
    var groups: [ProxyGroup] = []
    var latencyByTag: [String: LatencyResult] = [:]
    var isTestingLatency: Bool = false
    var latencyTestProgress: Double = 0
    var startTime: Date?
    var lastTraffic: TrafficSample?   // 实时速率（bytes/s 差值）
    var lastError: String?

    // 控制方法（实际实现为 async，见下方注释）
    func toggle()                          // 切换连接状态
    func start() async throws              // 启动 sing-box
    func stop() async                      // 停止（等进程退出+关代理后才返回）
    func restart() async throws
    func switchNode(groupTag: String, nodeTag: String) async throws
    func refreshGroups() async             // 从 /proxies 同步组与模式
    func setMode(_ mode: ProxyMode) async  // 热切路由模式
    func testLatency() async               // 批量测速（限并发 10）

    // 实现备注（实现时与初稿的偏差，以实现为准）：
    // - switchNode 用 tag 而非 UUID：sing-box 内核标识就是 tag，
    //   再加 UUID↔tag 映射是多此一举。ProxyGroup.memberTags 同理存 tag。
    // - 流量速率用 /connections 总量差值计算，不用 /traffic ——
    //   后者是 WebSocket 流式端点，URLSession.data(for:) 会永久挂起。
    // - testLatency 不接收 nodeIDs：直接测当前所有组的全部成员。

    // 内部方法（私有）
    private func buildConfig() throws -> URL
    private func startProcess(configURL: URL) throws
    private func stopProcess()
}

// MARK: - SubscriptionManager

@Observable
final class SubscriptionManager {
    static let shared = SubscriptionManager()

    var subscriptions: [Subscription] = []

    func addSubscription(url: String, name: String) async throws
    func updateSubscription(id: UUID) async throws
    func updateAll() async
    func deleteSubscription(id: UUID)
    func parseSubscription(data: Data) throws -> [ProxyNode]
}

// MARK: - SystemProxy

struct SystemProxy {
    static func enable(httpPort: Int, socksPort: Int) throws
    static func disable() throws
    static var isEnabled: Bool { get }
}

// MARK: - SpeedTestService

actor SpeedTestService {
    func test(node: ProxyNode, timeout: TimeInterval = 5.0) async -> Int?  // 返回延迟(ms)，nil=超时
    func testBatch(nodes: [ProxyNode]) async -> [UUID: Int]
}

// MARK: - SingBoxAPIClient

actor SingBoxAPIClient {
    var baseURL: URL  // sing-box API 地址，默认 http://127.0.0.1:9090

    func getProxies() async throws -> [ProxyGroup]
    func getConnections() async throws -> [Connection]
    func switchProxy(groupName: String, nodeName: String) async throws
    func closeConnection(id: UUID) async throws
    func getTraffic() async throws -> (up: Int64, down: Int64)
}
```

---

## 4. 数据模型规范

所有模型必须满足以下要求：

```swift
// 示例：ProxyNode
struct ProxyNode: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let server: String
    let port: Int
    let `protocol`: String        // "shadowsocks", "vmess", "vless", "trojan", "hysteria2"...
    let country: String           // ISO 3166-1 alpha-2，如 "US", "JP", "HK"
    var latency: Int?             // ms，nil 表示未测速或超时
    let subscriptionID: UUID?     // 来源订阅

    // 用于 UI 展示的计算属性
    var displayLatency: String {
        guard let latency else { return "超时" }
        return "\(latency)ms"
    }

    var latencyColor: Color {
        guard let latency else { return .secondary }
        if latency < 200 { return .green }
        if latency < 500 { return .yellow }
        return .red
    }
}

enum ProxyMode: String, Codable, CaseIterable, Identifiable {
    case global = "全局"
    case rule = "规则"
    case direct = "直连"
    var id: String { rawValue }
}

struct ProxyGroup: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let type: GroupType          // "selector", "url-test", "load-balance", "fallback"
    let icon: String             // SF Symbol 名称
    var nodes: [ProxyNode]
    var selectedNodeID: UUID?
}

enum GroupType: String, Codable {
    case selector, urlTest, loadBalance, fallback
}
```

---

## 5. UI 组件规范

> **设计事实来源：`Design/`**。本节规范均从 `Design/prototype/Silkway.dc.html` 提取，
> 两者冲突时以设计稿为准。开发前先 `open Design/prototype/Silkway.dc.html` 看一遍交互。

### 5.1 菜单栏弹窗

- **尺寸**：固定宽度 `340px`，高度自适应（最大约 500px，超出可滚动）
- **背景**：`.ultraThinMaterial` 或设计稿指定颜色
- **圆角**：`16px`（与 macOS 系统菜单风格一致）
- **交互**：点击外部自动关闭（`MenuBarExtra` 默认行为）

### 5.2 设置面板

- **容器**：`TabView`，Sidebar 样式（macOS 14+）
- **最小尺寸**：`minWidth: 700, minHeight: 500`
- **默认尺寸**：`800 × 600`

### 5.3 颜色 Token（深色优先）

> 数值来源：`Design/prototype/Silkway.dc.html` 分区 03。修改前先改设计稿。

**强调色策略：跟随系统。** 设计稿里的 `#0A84FF` 是 macOS 深色默认强调色，仅为视觉参考值，**代码里必须用 `Color.accentColor`**。

**但状态色不跟随系统** —— 否则用户把强调色设成红色时，「已连接」会变红，语义崩塌。

```swift
enum ColorToken {
    // ── 背景 / 文字：用系统语义色，自动适配深浅色 ──
    static let window     = Color(NSColor.windowBackgroundColor)   // 设计参考 #1C1C1E
    static let sidebar    = Color(NSColor.underPageBackgroundColor) // 设计参考 #252528
    static let card       = Color(NSColor.controlBackgroundColor)  // 设计参考 #2C2C2E
    static let separator  = Color(NSColor.separatorColor)          // 设计参考 #2E2E31
    static let textPrimary   = Color(NSColor.labelColor)           // 设计参考 #F2F2F7
    static let textSecondary = Color(NSColor.secondaryLabelColor)  // 设计参考 #98989E

    // ── 强调色：跟随系统（已定案） ──
    static let accent = Color.accentColor

    // ── 状态色：锁定固定值，区分深浅色 ──
    static let success  = Color(light: 0x248A3D, dark: 0x32D74B)  // 已连接 / 低延迟
    static let warning  = Color(light: 0xB25000, dark: 0xFFD60A)  // 中延迟 / 命中规则
    static let error    = Color(light: 0xD70015, dark: 0xFF453A)  // 高延迟 / 拒绝
    static let disabled = Color(NSColor.tertiaryLabelColor)       // 超时 / 断开
}
```

`Color(light:dark:)` 需自行实现，封装 `NSColor(name:dynamicProvider:)`，放在 `Utils/Extensions.swift`。

### 5.4 延迟颜色规则（全局统一）

| 延迟 | Token | 深色 | 浅色 |
|------|-------|------|------|
| < 200ms | `success` | `#32D74B` | `#248A3D` |
| 200–500ms | `warning` | `#FFD60A` | `#B25000` |
| > 500ms | `error` | `#FF453A` | `#D70015` |
| nil / 超时 | `disabled` | `#8E8E93` | 系统三级标签色 |

⚠️ **浅色模式的「黄」是棕橙 `#B25000`，不是黄色**。纯黄在白底上对比度不足，无法通过可读性要求。不要自作主张改回黄色。

**所有显示延迟的地方必须使用 `LatencyBadge` 组件，禁止直接写颜色逻辑。**

### 5.5 SF Symbols 对照表

图标名称已由设计稿指定，**不得自行替换**：

❌ **菜单栏图标不在此表**。设计稿早期版本曾指定 `shield.lefthalf.filled` / `shield.slash`，
**该方案已废弃** —— 现改用地球轨道标识的自定义 template image，见 5.6。

| 位置 | SF Symbol |
|------|-----------|
| 电源开关 | `power` |
| 测速 | `speedometer` |
| 搜索 | `magnifyingglass` |
| 设置·通用 | `gearshape` |
| 设置·订阅 | `square.stack.3d.up` |
| 设置·代理节点 | `globe.asia.australia` |
| 设置·路由规则 | `list.bullet.indent` |
| 设置·DNS | `point.3.filled.connected.trianglepath.dotted` |
| 设置·连接日志 | `arrow.left.arrow.right` |
| 设置·关于 | `info.circle` |

### 5.6 App 图标规格

造型：**环绕地球的轨道箭头**（一条线路连通世界各地）。

| 项 | 值 |
|----|-----|
| 容器 | squircle，圆角半径 24% |
| 底色 | 160° 线性渐变 `#4AA8FF → #0A4FB0` |
| 图形留白 | 6% |
| 大尺寸（1024/512/256） | 保留经线与轨道后段（半透明表示穿行球体背面） |
| 小尺寸（64/32） | 只留赤道线并加粗描边 |
| 菜单栏 | 单色 template image，随系统自动反色 |

#### 菜单栏图标（自定义 template image）

**不用 SF Symbol。** 采用地球轨道标识的单色简化版：

| 项 | 值 |
|----|-----|
| 图形 | 只留赤道线并加粗描边，去掉经线与轨道后段（即 5.6 表中「小尺寸」规则） |
| 格式 | **PDF 矢量**首选；退而求其次则 PNG 16px @1x + 32px @2x |
| 尺寸 | 16×16pt |
| 填充 | 纯黑 + alpha |
| 状态 | 已连接 / 断开两套，断开态叠加斜杠（参照系统 `wifi.slash`） |

必须设 `NSImage.isTemplate = true`。置位后系统**只用 alpha 通道**，RGB 被忽略，所以纯白或纯黑填充都行；但忘了置位则白色图标在浅色菜单栏不可见。

⚠️ **当前无导出资产**。图标仅存在于设计稿渲染结果，`Design/assets/` 为空，需在 P0 任务 1 前补齐切图，清单见 `Design/README.md`。

---

## 6. 编码规范

### 6.1 命名

- 类/结构体：`PascalCase`
- 方法/属性：`camelCase`
- 私有属性前缀：`private var _internalState`（仅在需要时）
- 布尔属性：使用 `is` / `has` / `should` 前缀，如 `isRunning`, `hasError`

### 6.2 View 组织

```swift
// ✅ 推荐：按功能拆分子 View
struct MenuBarView: View {
    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
            Divider()
            GroupList()
            Divider()
            ActionFooter()
        }
    }
}

// ❌ 禁止：一个 View 超过 200 行
```

### 6.3 错误处理

```swift
// ✅ 推荐：使用 Result 或 throws，错误显示在 UI
func start() throws {
    guard FileManager.default.fileExists(atPath: configPath) else {
        throw SilkwayError.configNotFound
    }
    // ...
}

enum SilkwayError: LocalizedError {
    case configNotFound
    case singBoxNotFound
    case subscriptionInvalid
    case apiConnectionFailed

    var errorDescription: String? {
        switch self {
        case .configNotFound: return "配置文件不存在"
        case .singBoxNotFound: return "sing-box 内核未找到"
        case .subscriptionInvalid: return "订阅链接无效或解析失败"
        case .apiConnectionFailed: return "无法连接到 sing-box 控制 API"
        }
    }
}
```

### 6.4 并发

- 网络请求、文件操作、进程管理：**必须使用 `async/await`**
- sing-box API 轮询：使用 `Task { ... }` + `try await Task.sleep(...)`
- 测速：使用 `TaskGroup` 并发测速，但限制并发数（如最多 10 个同时）
- UI 更新：必须在主线程，`@Observable` 自动处理，但手动回调需 `MainActor.run`

---

## 7. sing-box 集成规范

### 7.1 嵌入方式

- sing-box 二进制放在 `Resources/sing-box`
- 运行时路径：`Bundle.main.url(forResource: "sing-box", withExtension: nil)!`
- 配置文件路径：`~/Library/Application Support/Silkway/config.json`
- 锁定版本：**sing-box 1.13.19**（已验证），升级前必须重跑第 10.1 节任务 0

⚠️ 官方二进制是 `adhoc, linker-signed`（实测 `Signature=adhoc`）。**这只在分发时构成问题**：

| 场景 | adhoc 内嵌二进制 |
|------|----------------|
| 本机开发/自用（Development 证书或 Xcode 直接 Run） | ✅ 本地运行不校验嵌套二进制签名 |
| 分发他人（Developer ID + 公证） | ❌ 公证要求所有可执行文件同证书重签 |

分发时的重签命令：

```bash
codesign --force --options runtime --timestamp \
         --sign "Developer ID Application: <NAME> (<TEAM_ID>)" \
         "$BUILT_PRODUCTS_DIR/Silkway.app/Contents/Resources/sing-box"
```

### 7.2 启动参数

```swift
let process = Process()
process.executableURL = singBoxURL
process.arguments = [
    "run",
    "-c", configURL.path,
    "-D", workingDirectory.path
]
// 工作目录用于 sing-box 生成日志、缓存等
```

### 7.3 API 启用

sing-box 配置中必须包含 `experimental.clash_api`：

```json
{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:<动态端口>",
      "secret": ""
    },
    "cache_file": {
      "enabled": true,
      "path": "cache.db"
    }
  }
}
```

❌ **不要写 `clash_api.store_selected`**。该字段自 sing-box 1.8.0 已废弃，写了会直接 FATAL：

```
create clash-server: cache_file and related fields in Clash API is deprecated
in sing-box 1.8.0, use experimental.cache_file instead.
```

节点选择的持久化现在由 `cache_file.enabled` 接管，无需单独开关。

### 7.4 配置生成模板

`ConfigBuilder` 生成的配置必须包含以下结构：

```json
{
  "log": { "level": "info", "output": "sing-box.log" },
  "dns": { "servers": [ { "tag": "local", "type": "local" } ] },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": <动态> }
  ],
  "outbounds": [ /* 从订阅解析的节点 + selector 策略组 */ ],
  "route": { "rules": [], "final": "PROXY" },
  "experimental": { /* 见 7.3，必含 clash_api + cache_file */ }
}
```

#### DNS 格式（已变更）

sing-box 1.12.0 弃用了旧 DNS 格式，**1.14.0 将彻底移除**。写错会 FATAL：

| | 写法 |
|---|---|
| ❌ 旧 | `{ "tag": "google", "address": "tls://8.8.8.8" }` |
| ✅ 新 | `{ "tag": "google", "type": "tls", "server": "8.8.8.8" }` |

#### 默认 DNS 不得硬编码境外 DoT

实测：默认用 `tls://8.8.8.8` 会导致代理**完全不可用**（所有请求 502）。日志：

```
lookup cp.cloudflare.com: (exchange6: dial TLS connection: EOF |
                           exchange4: dial TLS connection: EOF)
```

原因：853 端口 TCP 能建连但 TLS 握手被 RST。这形成死锁 —— **要连代理先得解析机场域名，要解析域名先得连代理**。

默认必须用 `{ "type": "local" }`（系统解析器）。后续做 DNS 分流时，机场域名走 local，其余走代理 DNS。

#### 端口必须动态分配

实测：固定 `9090` 启动直接失败 ——

```
external controller listen error: listen tcp 127.0.0.1:9090:
bind: address already in use
```

9090 是 Clash 生态的事实标准端口，用户装了任何其他客户端（ClashX / Verge / FlClash……）就会撞车，且 `lsof` 非 root 看不到占用者，排查成本极高。

`ConfigBuilder` 必须在生成配置前探测空闲端口（bind 到 port 0 由内核分配，读回后关闭），并把实际端口存入 `SingBoxManager`，供 `SingBoxAPIClient` 和 `SystemProxy` 复用。参考实现见 `spike/Spike.swift` 中的 `findFreePort()`。

---

## 8. TUN 模式与特权 Helper

> 本节是全项目技术难度最高的部分，也是唯一无法靠 Swift 代码本身绕过的部分。
> Agent 在实现 P2「TUN 模式」之前必须完整阅读本节。

### 8.1 为什么必须要 root

第 7.4 节的默认配置只有 `mixed` / `http` inbound，属于**系统代理模式**：只有主动读取系统代理设置的程序才会走代理。以下场景会直接漏流量：

- 大量 CLI 工具（`go get`、部分 `curl` 用法、Docker 守护进程）
- 硬编码直连的 Electron / Java 应用
- 所有 UDP 流量（系统代理只代理 TCP）

TUN 模式通过创建虚拟网卡接管全部流量来解决，但它需要两项特权操作：

| 操作 | 需要的权限 |
|------|-----------|
| 创建 `utun` 虚拟网卡 | root |
| 修改路由表（`auto_route`） | root |
| 写入 pf 防火墙锚点（`strict_route`） | root |

**`SingBoxManager` 里的 `Process()` 以普通用户身份运行，拉不起 TUN。** 这是架构级约束，不是配置问题。

### 8.2 三种方案与选型

| 方案 | 机制 | 结论 |
|------|------|------|
| A. SMAppService + XPC | root 态 LaunchDaemon 代跑 sing-box | ✅ **本项目采用** |
| B. NetworkExtension | `NEPacketTunnelProvider`，sing-box 经 gomobile 编译为库嵌入 | ❌ 需向 Apple 单独申请 entitlement，且无法用子进程模式，与第 7 节架构冲突 |
| C. setuid root 二进制 | 给 sing-box 加 setuid 位 | ❌ 严重安全漏洞，任何本地进程可提权，禁止使用 |

方案 A 的代价：主 App 与 Helper 必须**同 Team ID 签名**（免费的 Apple Development 证书即可，Apple ID 登录 Xcode 自动获得），且**必须关闭 App Sandbox**。公证只有分发时才需要。

### 8.3 Helper 的安装与生命周期

macOS 13+ 使用 `SMAppService`（旧的 `SMJobBless` 已废弃，不要采用网上的老教程）：

```swift
import ServiceManagement

let service = SMAppService.daemon(plistName: "com.silkway.helper.plist")

switch service.status {
case .enabled:          break                     // 已就绪
case .requiresApproval: openLoginItemsSettings()  // 引导用户去系统设置授权
case .notRegistered:    try service.register()    // 首次注册，会弹出授权请求
case .notFound:         throw HelperError.bundleCorrupted
@unknown default:       break
}
```

构建产物的布局是固定的，路径写错会静默失败：

```
Silkway.app/Contents/
├── MacOS/
│   ├── Silkway                       # 主 App
│   └── SilkwayHelper                 # Helper 可执行文件
└── Library/LaunchDaemons/
    └── com.silkway.helper.plist      # BundleProgram 指向 Contents/MacOS/SilkwayHelper
```

用户授权入口在**系统设置 → 通用 → 登录项与扩展 → 后台**，注册后不会自动启用，必须在 UI 里明确引导，否则用户只会看到「开关点了没反应」。

卸载时必须调用 `service.unregister()`，否则会残留一个 root 守护进程。

### 8.4 XPC 通信与安全校验（不可省略）

Helper 以 root 运行并接受外部指令，**不校验调用方等于开了一个本地提权后门**。macOS 13+ 有官方 API，不要手写 audit token 校验：

```swift
// 主 App 侧
let conn = NSXPCConnection(machServiceName: "com.silkway.helper", options: .privileged)
conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
conn.setCodeSigningRequirement(
    "anchor apple generic and identifier \"com.silkway.helper\" " +
    "and certificate leaf[subject.OU] = \"<TEAM_ID>\""
)
conn.resume()

// Helper 侧：在 listener(_:shouldAcceptNewConnection:) 中对反向做同样校验
newConnection.setCodeSigningRequirement(
    "anchor apple generic and identifier \"com.silkway.app\" " +
    "and certificate leaf[subject.OU] = \"<TEAM_ID>\""
)
```

Helper 的 plist 必须声明 `MachServices`，否则连接建立不起来：

```xml
<key>MachServices</key>
<dict><key>com.silkway.helper</key><true/></dict>
```

**XPC 接口保持最小化**。只暴露必要动作，不要提供「执行任意命令」这类通用方法：

```swift
@objc protocol HelperProtocol {
    func helperVersion(reply: @escaping (String) -> Void)
    func startSingBox(configPath: String, reply: @escaping (Bool, String?) -> Void)
    func stopSingBox(reply: @escaping (Bool) -> Void)
    func cleanupRoutes(reply: @escaping (Bool) -> Void)
}
```

### 8.5 TUN inbound 配置

启用 TUN 时 `ConfigBuilder` 需要替换 inbound（语法对应 sing-box 1.13，已实测验证）：

```json
{
  "type": "tun",
  "tag": "tun-in",
  "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
  "mtu": 9000,
  "auto_route": true,
  "strict_route": true,
  "stack": "gvisor"
}
```

- ⚠️ **`auto_detect_interface` 在 1.13 挪到了 `route` 层**（`"route": {"auto_detect_interface": true}`），放 inbound 层会报 `json: unknown field`。必须为 true，否则代理流量回流 TUN 死循环
- `stack` 在 macOS 上优先 `gvisor`（用户态实现，稳定性好于 `system`）
- TUN 模式下**必须关闭系统代理**，两者叠加会造成双重代理

### 8.6 本节专属陷阱

| 陷阱 | 后果 | 正确做法 |
|------|------|---------|
| App 崩溃时未清理路由表 | **用户整机断网**，且重启 App 也修不好 | Helper 侧注册 `terminationHandler` + 启动时先执行 `cleanupRoutes()` 兜底 |
| Helper 与主 App 版本不匹配 | 调用未实现的 XPC 方法直接崩溃 | 连接后先调 `helperVersion()` 比对，不一致则 `unregister()` 后重装 |
| 从 Xcode DerivedData 直接运行 | `SMAppService.register()` 报错 `Operation not permitted` | 调试特权功能必须先把 .app 拷到 `/Applications` 再启动 |
| 开启了 App Sandbox | Helper 注册失败、`networksetup` 无权限 | 关闭沙盒；本项目不上架 App Store，无沙盒要求 |
| TUN 与系统代理同时开启 | 双重代理，延迟翻倍或直接不通 | `SingBoxManager` 中两种模式互斥，切换时先关闭另一方 |
| 未处理 `.requiresApproval` | 用户点开关无反应且无任何提示 | 状态为 `.requiresApproval` 时必须跳转系统设置并显示引导文案 |

调试命令：

```bash
sudo launchctl list | grep silkway          # 确认 daemon 是否加载
log stream --predicate 'subsystem == "com.silkway.helper"'   # Helper 日志
netstat -rn | head -20                      # 检查路由表是否被正确清理
```

### 8.7 实施建议

TUN 是独立于主链路的增量功能。**建议 P0–P1 全部完成、系统代理模式跑通之后再启动本节**，原因：

1. 系统代理模式已能覆盖大部分开发者日常场景，可先交付可用版本
2. Helper 的调试循环极慢（改代码 → 重签名 → 拷贝到 /Applications → 重新授权），过早引入会拖慢核心功能迭代
3. **无需付费账号即可开发**：Apple ID 免费登录 Xcode 拿到的 Apple Development 证书就能完成签名 + 本机授权全流程（2026-09 定案：本项目自用为主，不支付 $99/年）。唯一的前置是**必须登录一个 Apple ID**，纯 adhoc 签名无法注册 Helper

---

## 9. 已知陷阱（Agent 必读）

| 陷阱 | 后果 | 正确做法 |
|------|------|---------|
| 在 View 中直接调用 `Process()` | 内存泄漏、UI 卡顿 | 所有进程操作封装在 `SingBoxManager` |
| 忘记处理 sing-box 崩溃 | 应用状态与实际不一致 | 监听 `process.terminationHandler`，崩溃后自动 `stop()` |
| 使用 `UserDefaults` 存大量节点数据 | 性能差、同步慢 | 节点数据用 SwiftData 或 JSON 文件存储 |
| 菜单栏弹窗中使用 `NavigationStack` | 行为异常、层级混乱 | 菜单栏弹窗只用 `VStack + List`，设置面板才用导航 |
| 测速不限制并发 | 内存爆炸、网络阻塞 | `TaskGroup` 配合 `withLimitedConcurrency` 或信号量 |
| 忽略 `MenuBarExtra` 的 `.window` 样式 | 弹窗显示为传统菜单 | 必须 `.menuBarExtraStyle(.window)` |
| 系统代理设置失败不提示 | 用户以为已连接实际没走代理 | `SystemProxy.enable()` 必须 `try/catch` 并反馈到 UI |
| 深色模式硬编码颜色 | 浅色模式下显示异常 | 使用 `NSColor` 动态颜色或 `ColorToken` |
| App 退出不停 sing-box | 孤儿进程占端口和 cache.db 文件锁，下次启动 FATAL "initialize cache-file: timeout"（2026-09-03 真实发生） | `applicationShouldTerminate` 返回 `.terminateLater` 先 `await stop()` 再退出；启动前用 pid 文件 + pgrep 命令行特征（含本 App 工作目录）回收孤儿，绝不无差别杀 sing-box |
| `toggle()` 用 `try?` 吞启动错误 | 用户点连接"没反应"，无错误提示 | `start()` 所有失败路径必须写 `lastError`，UI 空状态区展示错误文案 |
| 6 位 hex 按 ARGB 解析取 alpha | `(0x248A3D >> 24) = 0` → alpha=0 全透明，所有 success 色元素「隐身」（2026-09-03 真实 bug：电源键连接后消失） | 6 位 RGB hex 锁定 alpha=1.0；`NSColor(rgb:)` 不要做成 argb |
| networksetup 输出读 stderr | 数据输出和错误信息全在 **stdout**，stderr 永远空 → activeServices 永远「输出为空」，**系统代理从未生效**（2026-09-03 真实 bug，手动 shell 测试正常但 App 里挂了） | `run()` 捕获 stdout；exit code ≠ 0 才为失败 |
| daemon plist 写 `RunAtLoad=false` | launchd 加载了 job 但**永远不启动**（无触发条件），API 超时且日志为空（2026-09-08 真实 bug） | TUN daemon 必须 `RunAtLoad=true` + `KeepAlive=true` |
| TUN 模式不加 `ip_is_private` 直连规则 | 路由器后台/打印机/NAS/AirDrop 全部被送去代理，局域网全挂 | route.rules 首位加 `{"ip_is_private": true, "outbound": "direct-out"}` |
| TUN 模式不劫持 DNS | DNS 请求当普通 UDP 走 final → 代理，慢且可能形成「解析机场域名需先连上机场」死循环 | 加 `{"action": "hijack-dns", "protocol": "dns"}` + `route.default_domain_resolver` |
| 代理协议跑 ICMP | `icmp is not supported by default outbound`，ping 全废 | TUN 下加 `{"network": "icmp", "outbound": "direct-out"}` |
| TUN 配置 IPv6 地址但机场无 v6 出口 | 应用拿到原生 v6 地址后进 TUN，direct 出站报 `no route to host`；双栈站点卡死（2026-09-08 实测电信 240e:: 全网段） | TUN 只配 IPv4 地址 + `dns.strategy: prefer_ipv4`；v6 流量不进 TUN，macOS 自动降级 v4 |
| 测试读 `AppConfigStore.shared` 真实配置 | 用户开了 TUN 后，集成测试也走 TUN 分支 → SMAppService 在测试 bundle 里必挂 | 测试必须注入 `configProvider = { AppConfig() }`（同 `nodeProvider`/`appSupportDir`） |
| 试图用 `Process()` 启动 TUN 模式 | 权限不足，静默失败 | TUN 必须经特权 Helper 启动，见第 8 节 |
| 开启 App Sandbox | Helper 注册与系统代理设置全部失效 | 保持沙盒关闭，见 8.6 |
| 硬编码端口 9090 / 2080 | 与用户已装的其他 Clash 客户端撞端口，启动即失败 | 运行时探测空闲端口，见 7.4 |
| 默认 DNS 用境外 DoT | 代理启动即 502，且报错指向节点而非 DNS，极难定位 | 默认 `{"type":"local"}`，见 7.4 |
| 直接打包官方 sing-box 二进制 | **分发时**公证失败（本机自用无碍） | 分发构建用 Developer ID 重签，见 7.1 |
| 认为 `sing-box check` 通过就能跑 | check 不验证端口占用、DNS 可达性 | 启动后必须轮询 Clash API 确认就绪（~200ms） |
| 用 `URLSession.data(for:)` 调 `/traffic` | 该端点是 WebSocket 流，请求永久挂起，进程无法退出 | 用 `/connections` 的 upload/download 总量差值算速率 |
| Swift Testing 默认并行跑套件内测试 | 共享单例/真实进程的两个测试互相干扰、进程被孤立 | 涉及共享状态的套件加 `@Suite(.serialized)` |

---

## 10. 开发任务清单（按优先级）

Agent 每次只领取一个任务，完成后更新状态。**同优先级内按表中顺序执行，不得跳号。**

### 10.1 P0 —— 端到端最小闭环

目标：贴一个订阅链接 → 选节点 → 浏览器能走代理。此前不做任何锐化。

| 序 | 任务 | 文件 | 状态 |
|----|------|------|------|
| 0 | **技术验证**：`Process()` 拉起 sing-box + Clash API 驱动 | `spike/Spike.swift` | ✅ 14/14 通过 |
| 1 | 项目骨架 + MenuBarExtra + Settings 空壳 | `SilkwayApp.swift`, `SettingsView.swift` | ⬜ |
| 2 | 数据模型定义（严格按第 4 节规范） | `Models/` 全部 | ⬜ |
| 3 | 订阅拉取 + Base64/URL/Clash YAML 解析 + 节点模型转换 | `SubscriptionManager.swift` | ⬜ |
| 4 | ConfigBuilder 生成 sing-box 配置 JSON | `ConfigBuilder.swift` | ⬜ |
| 5 | SingBoxManager 进程管理（启动/停止/崩溃监听） | `SingBoxManager.swift` | ✅ 已实现，含真实 sing-box 集成测试（启动→热切→流量→停止全链路） |
| 6 | 系统代理设置（HTTP/HTTPS/SOCKS） | `SystemProxy.swift` | ⬜ |
| 7 | 菜单栏弹窗 UI（开关 + 策略组列表 + 节点选择） | `MenuBarView.swift` 及子视图 | ✅ 已实现（7 个视图文件，图标用 SF Symbol 占位） |

> **为什么 UI 排在最后**：没有真实节点数据时，菜单栏 UI 只能靠 mock 写，等真数据接入必然返工（策略组嵌套层级、节点名长度、延迟缺失态都是 mock 猜不准的）。订阅解析是脏活但无不确定性，先啃掉它，UI 一次成型。

### 10.2 P1 —— 可用性

| 任务 | 文件 | 状态 |
|------|------|------|
| sing-box API 客户端（获取连接、热切节点） | `SingBoxAPIClient.swift` | ✅ 已实现 |
| 真实凭证解析（URI → 完整 outbound） | `SubscriptionParser.swift` 的 `makeOutboundJSON` 系列 | ✅ 已实现，sing-box check 测试背书 |
| 订阅/节点持久化 | `ProxyNodeStore.swift` | ✅ 已实现（JSON 原子写，不用 CoreData/UserDefaults） |
| 延迟测速（HTTP，限并发 10） | 合并在 `SingBoxManager.testLatency`（未拆 SpeedTestService） | ✅ 已实现，结果回写 store |
| 订阅管理 UI（添加/更新/删除/错误显示） | `SubscriptionView.swift` | ✅ 已实现 |
| 连接日志实时展示 + 单条断开 | `ConnectionView.swift`（合并在视图内，未拆 LogParser） | ✅ 已实现 |
| 流量统计图表（Swift Charts，1 分钟窗口） | `TrafficChart.swift` | ✅ 已实现 |
| 自动更新订阅 + 后台检查（30 分钟轮询） | `AutoUpdateService.swift` + `SubscriptionManager.updateAllDue` | ✅ 已实现 |
| 配置热重载（订阅变更不重启示波器） | `SingBoxManager.reloadConfigIfRunning` + API `PUT /configs` | ✅ 已实现 |

### 10.3 P2 —— TUN 与特权（启动前先读第 8 节）

> **v1.17 定案：用 SMAppService.daemon 直接把包内 sing-box 注册为 launchd daemon，**  
> **不走独立 XPC Helper**。理由：XPC Helper 的调试循环极慢（改代码→重签名→拷 /Applications→重新授权），  
> 而 daemon 方案把 sing-box 当 root 进程跑，Clash API 照旧 —— 策略组/测速/连接日志零改动。  
> 代价：plist 里写死 `/Applications/Silkway.app` 路径（手册 8.6 本来就要求 App 在 /Applications）。

| 任务 | 文件 | 状态 |
|------|------|------|
| sing-box 嵌入 bundle + 同证书重签（SMAppService 要求） | `generate-xcodeproj.py` 的 Re-sign 阶段 | ✅ 已实现 |
| daemon plist + Copy Files 构建阶段到 `Contents/Library/LaunchDaemons/` | `Resources/LaunchDaemons/com.silkway.singbox.plist` | ✅ 已实现 |
| TunManager：SMAppService.daemon 注册/注销/批准引导 | `TunManager.swift` | ✅ 已实现 |
| TUN inbound 配置生成（1.13 语法，`auto_detect_interface` 在 route 层） | `ConfigBuilder.inbounds` | ✅ 已实现，sing-box check 背书 |
| SingBoxManager TUN 分支（与系统代理互斥，共用 Clash API） | `SingBoxManager.startTUN/stop/reloadConfigIfRunning` | ✅ 已实现 |
| 真机验证：注册 → 批准 → TUN 生效 | 需要 /Applications 中运行 + 用户批准 | ✅ 已验证（2026-09-08，全网站可访问） |
| 路由表异常清理与崩溃兜底 | sing-box 的 `auto_route` 自管理 + launchd KeepAlive | ✅ 由 sing-box/launchd 处理 |
| 规则编辑界面 | `RuleView.swift`（绕过大陆 + 自定义直连域名） | ✅ 已实现（A 阶段顺手完成） |

### 10.4 P3 —— 锐化

| 任务 | 文件 | 状态 |
|------|------|------|
| 快捷键支持 | `GeneralView.swift` | ⬜ |
| iCloud / WebDAV 配置同步 | 新增 Service | ⬜ |

---

## 11. 外部依赖

**当前依赖：无。** 本项目目标是零第三方依赖。

| 包名 | 用途 | 来源 |
|------|------|------|
| — | — | — |

**原则**：能用 Foundation 原生实现的，不引入第三方库。

常见诉求的原生替代方案，Agent 不得绕过：

| 想加的库 | 用什么替代 | 原因 |
|---------|-----------|------|
| Alamofire | `URLSession` + `async/await` | Alamofire 的价值在于封装 completion handler 地狱；Swift 已原生支持 `try await URLSession.shared.data(from:)`，引入它只是多一层间接 |
| SwiftyJSON | `Codable` | SwiftyJSON 用动态下标绕过类型系统，与第 4 节「所有模型必须 Codable」直接冲突，会把解析错误从编译期推到运行期 |
| 图表库 | `Swift Charts` | 系统自带（macOS 13+），已在 `TrafficChart.swift` 使用 |
| YAML 解析库 | 手写子集解析器 | 仅需解析 Clash 订阅的固定子集；若确实阻塞，可作为唯一例外提案讨论（Yams） |

新增依赖需先在本表登记并说明为何无法原生实现。

---

## 12. 如何开始（Agent 第一步）

如果你是第一个接入的 Agent：

1. 确认 Xcode 15+ 和 macOS 14+ SDK 可用
2. 创建 macOS App 项目（SwiftUI，min macOS 14.0）
3. 按第 2 节目录结构创建文件夹
4. 实现 `SilkwayApp.swift` + `AppDelegate.swift`，确认菜单栏图标能显示
5. 实现 `SettingsView.swift` 空壳 Tab 页
6. 提交代码并更新第 10 节任务状态

注意：第一步**不要**碰第 8 节的特权 Helper，先把系统代理模式跑通（见 8.7）。

---

*本文档版本: v1.20*  
*v1.1：新增第 8 节「TUN 模式与特权 Helper」，原 8–11 节顺延为 9–12*  
*v1.2：第 10 节任务清单重排（P0 改为端到端闭环，UI 后置）；第 11 节清空第三方依赖*  
*v1.3：完成任务 0 技术验证。修正 7.3 `store_selected` 废弃、7.4 DNS 旧格式两处错误；*  
*新增端口动态分配、DNS 死锁、二进制重签名三项约束及 5 条陷阱*  
*v1.4：接入 `Design/` 设计资产。第 5 节换为设计稿真实 Token（含浅色变体），*  
*新增 5.5 SF Symbols 对照表、5.6 App 图标规格；强调色定案为跟随系统*  
*v1.5：菜单栏图标定案为地球轨道单色版（自定义 template image），*  
*废弃原 `shield.lefthalf.filled` / `shield.slash` 方案*  
*v1.6：P0 任务 1/2/3/4/6 完成；Xcode 工程手写生成脚本并 build 通过*  
*v1.7：任务 5 完成。SingBoxManager + SingBoxAPIClient + PortAllocator，34 项测试全过；*  
*新增 /traffic WebSocket 挂起、Swift Testing 并行共享状态两条陷阱*  
*v1.8：任务 7 完成。菜单栏弹窗 7 视图 + Settings 空壳 7 Tab；*  
*3.3 契约同步实际实现（switchNode 用 tag、async 化）；延迟色阶收敛到 LatencyLevel.resolve 唯一入口*  
*v1.9：修正签名门槛表述 —— Apple Development 免费证书即可本机开发 Helper/嵌二进制；*  
*Developer ID + 公证仅分发需要（本项目定案：自用为主，不付费）*  
*v1.10：P1 全部完成（42 项测试全过）。真实凭证解析（vmess/vless/trojan/ss/hy2 → 完整 outbound）、*  
*ProxyNodeStore 持久化、订阅管理 UI、连接日志 + 流量图、自动更新 + 配置热重载；*  
*新增 sing-box check 集成测试（spike 二进制校验生成配置的 schema）*  
*v1.11：图标资产接入。AppIcon 10 槽位 + 菜单栏连/断 template PDF（纯黑+alpha 已验证）；*  
*generate-xcodeproj.py 改为不覆盖真实图标；About 页显示 AppIcon + 版本*  
*v1.12：真实订阅端到端验证通过（「白月光」103 节点 SS 全凭证、sing-box check ✓、*  
*隧道出网 HTTP 204 ✓）。新增 RealSubscriptionTests（读真实 store，store 不存在自动跳过）；*  
*修复两个测试隔离问题：SingBoxManager.appSupportDir / nodeProvider 可注入*  
*v1.13：修「点连接没反应」三连 bug —— App 退出留孤儿 sing-box、新进程抢 cache.db 锁超时、*  
*错误被 try? 吞掉不显示。加 pid 文件 + pgrep 特征扫描回收孤儿、applicationShouldTerminate 清理、*  
*lastError 上 UI（空状态区显示连接失败原因）*  
*v1.14：修「连接后电源键消失」—— NSColor(argb:) 把 6 位 hex 的高字节当 alpha，*  
*0x248A3D → alpha=0 全透明。改 NSColor(rgb:) 锁 alpha=1.0（波及所有状态色元素）*  
*v1.15：sing-box 格式订阅（完整 outbounds 数组）原样直通 —— 机场组装的 outbound 含完整凭证，*  
*不再只认 SIP008 shadowsocks。selector/urltest 等无 server 字段的条目自然被跳过*  
*v1.16：修「系统代理从未生效」—— networksetup 数据输出在 stdout 而非 stderr，*  
*run() 读错管道导致 activeServices 永远失败。加真实启停集成测试（enable→验证→disable→验证）*  
*v1.17：A 阶段（4 个设置 Tab：通用/代理节点/路由规则/DNS）+ B 阶段 TUN 模式骨架完成；*  
*P2 定案改用 SMAppService.daemon 直接注册包内 sing-box（不走 XPC Helper）；*  
*sing-box 嵌入 bundle + 同证书重签；TUN 配置 1.13 语法实测（auto_detect_interface 在 route 层）*  
*v1.18：TUN 真机跑通（utun7 / root daemon / 真实流量）。修 plist RunAtLoad=false 导致 daemon 永不启动；*  
*补齐 TUN 必备路由规则：局域网直连 / DNS 劫持 / ICMP 直连 / default_domain_resolver*  
*v1.19：修「有的网站打不开」—— 双栈站点卡死根因是 TUN 接管了 IPv6 但 SS 机场无 v6 出口；*  
*TUN 改纯 IPv4 + DNS prefer_ipv4；绕过大陆默认开启 + 首次启动自动下载规则集*  
*v1.20：TUN 全部真机验证通过。绕过大陆分流生效（微博/B站直连、ChatGPT/Google 走代理）*  

*最后更新: 2026-09-02*  
*如有架构变更，必须同步更新本文档。*  
