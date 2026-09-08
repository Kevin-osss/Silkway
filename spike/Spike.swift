// Silkway 技术验证 —— 对应手册第 10.1 节任务 0
//
// 验证目标（手册第 3.2 / 7 节的核心架构断言）：
//   1. Swift Process() 能以普通用户身份拉起 sing-box 子进程
//   2. Clash API (127.0.0.1:9090) 可用，能返回 /proxies
//   3. 能通过 API 热切换 selector 节点，无需重启进程
//   4. 流量能真正走通 mixed inbound (127.0.0.1:2080)
//   5. 进程能被干净终止，端口释放
//
// 运行：swift Spike.swift
// 注意：本文件是一次性验证脚本，不入正式代码库。

import Foundation

let workDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let binURL = workDir.appendingPathComponent("sing-box")
let cfgURL = workDir.appendingPathComponent("config.json")

var passed = 0, failed = 0

// ── 动态端口分配 ─────────────────────────────────────────────
// 固定 9090 会与用户已安装的其他 Clash 客户端冲突（实测已被占用）。
// ConfigBuilder 必须在生成配置前探测空闲端口。
func findFreePort() -> UInt16 {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0                       // 0 = 由内核分配
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sock, $0, &len)
        }
    }
    return UInt16(bigEndian: addr.sin_port)
}

let apiPort = findFreePort()
let mixedPort = findFreePort()
let apiBase = "http://127.0.0.1:\(apiPort)"

// ── 0. 生成配置（模拟 ConfigBuilder） ─────────────────────────
print("\n[0] ConfigBuilder 生成配置")
print("  · Clash API 端口: \(apiPort)   混合入站端口: \(mixedPort)")

let configJSON: [String: Any] = [
    "log": ["level": "info", "output": "sing-box.log"],
    // 不能硬编码境外 DoT：代理未连通时 tls://8.8.8.8 握手会被 RST，
    // 导致「要连代理先得解析域名、要解析域名先得连代理」的死锁。
    "dns": ["servers": [["tag": "local", "type": "local"]]],
    "inbounds": [
        ["type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": Int(mixedPort)]
    ],
    "outbounds": [
        ["type": "selector", "tag": "PROXY", "outbounds": ["direct-out"], "default": "direct-out"],
        ["type": "direct", "tag": "direct-out"]
    ],
    "route": ["rules": [], "final": "PROXY"],
    "experimental": [
        "clash_api": ["external_controller": "127.0.0.1:\(apiPort)", "secret": ""],
        "cache_file": ["enabled": true, "path": "cache.db"]
    ]
]

do {
    let data = try JSONSerialization.data(withJSONObject: configJSON, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: cfgURL)
    check("配置写入成功", true, "\(data.count) bytes")
} catch {
    check("配置写入成功", false, "\(error)")
    exit(1)
}

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { passed += 1; print("  ✅ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
    else  { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}

func api(_ path: String, method: String = "GET", body: [String: Any]? = nil) async -> (Int, Data)? {
    var req = URLRequest(url: URL(string: apiBase + path)!)
    req.httpMethod = method
    req.timeoutInterval = 5
    if let body {
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          let http = resp as? HTTPURLResponse else { return nil }
    return (http.statusCode, data)
}

// ── 1. 进程启动 ───────────────────────────────────────────────
print("\n[1] Process() 启动 sing-box")

let process = Process()
process.executableURL = binURL
process.arguments = ["run", "-c", cfgURL.path, "-D", workDir.path]

var terminatedUnexpectedly = false
process.terminationHandler = { p in
    if p.terminationStatus != 0 && !p.isRunning {
        terminatedUnexpectedly = true
    }
}

do {
    try process.run()
    check("Process.run() 成功", true, "PID \(process.processIdentifier)")
} catch {
    check("Process.run() 成功", false, "\(error)")
    print("\n验证中止：进程启动失败\n")
    exit(1)
}

// ── 2. 等待 Clash API 就绪 ────────────────────────────────────
print("\n[2] Clash API 就绪探测")

var ready = false
var waitedMs = 0
for _ in 0..<50 {
    if let (code, _) = await api("/version"), code == 200 { ready = true; break }
    try? await Task.sleep(nanoseconds: 100_000_000)
    waitedMs += 100
}
check("API 在 5s 内就绪", ready, ready ? "耗时 ~\(waitedMs)ms" : "超时")

guard ready else {
    process.terminate()
    print("\n验证中止：API 未就绪\n")
    exit(1)
}

if let (_, data) = await api("/version"),
   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    check("/version 返回版本号", j["version"] != nil, "\(j["version"] ?? "nil")")
}

// ── 3. /proxies 结构解析 ─────────────────────────────────────
print("\n[3] /proxies 数据结构")

var selectorTags: [String] = []
if let (code, data) = await api("/proxies"), code == 200,
   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
   let proxies = j["proxies"] as? [String: Any] {

    check("/proxies 返回 200", true, "\(proxies.count) 个 outbound")

    for (tag, v) in proxies {
        guard let d = v as? [String: Any], let type = d["type"] as? String else { continue }
        if type == "Selector" { selectorTags.append(tag) }
    }
    check("能识别 Selector 类型策略组", !selectorTags.isEmpty, "找到 \(selectorTags)")

    if let p = proxies["PROXY"] as? [String: Any] {
        check("PROXY 组含 all 字段（供 UI 渲染节点列表）", p["all"] != nil, "\(p["all"] ?? "nil")")
        check("PROXY 组含 now 字段（供 UI 显示当前选中）", p["now"] != nil, "now=\(p["now"] ?? "nil")")
    } else {
        check("PROXY 组存在", false)
    }
} else {
    check("/proxies 返回 200", false)
}

// ── 4. 热切换节点（不重启进程） ───────────────────────────────
print("\n[4] 通过 API 热切换节点")

let pidBefore = process.processIdentifier
if let (code, _) = await api("/proxies/PROXY", method: "PUT", body: ["name": "direct-out"]) {
    check("PUT /proxies/PROXY 成功", code == 204, "HTTP \(code)")
} else {
    check("PUT /proxies/PROXY 成功", false, "请求失败")
}
check("切换后进程未重启", process.isRunning && process.processIdentifier == pidBefore, "PID 仍为 \(pidBefore)")

// ── 5. 真实流量穿透 ──────────────────────────────────────────
print("\n[5] 流量穿透 mixed inbound (127.0.0.1:\(mixedPort))")

let curl = Process()
curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
curl.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}",
                  "--max-time", "10", "-x", "http://127.0.0.1:\(mixedPort)",
                  "http://cp.cloudflare.com/generate_204"]
let pipe = Pipe()
curl.standardOutput = pipe
try? curl.run()
curl.waitUntilExit()
let httpCode = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
check("经代理端口访问外网", httpCode == "204", "HTTP \(httpCode)（direct 出站，验证的是链路非翻墙）")

// ── 6. 连接与流量统计 ────────────────────────────────────────
print("\n[6] 连接统计（供 ConnectionView / TrafficChart 使用）")

if let (code, data) = await api("/connections"), code == 200,
   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    check("/connections 可用", true,
          "上行 \(j["uploadTotal"] ?? 0)B / 下行 \(j["downloadTotal"] ?? 0)B")
} else {
    check("/connections 可用", false)
}

// ── 7. 干净终止 ──────────────────────────────────────────────
print("\n[7] 进程终止与端口释放")

process.terminate()
process.waitUntilExit()
check("SIGTERM 后进程退出", !process.isRunning, "退出码 \(process.terminationStatus)")

try? await Task.sleep(nanoseconds: 500_000_000)
let stillUp = await api("/version") != nil
check("API 端口 \(apiPort) 已释放", !stillUp)

// ── 汇总 ─────────────────────────────────────────────────────
print("\n" + String(repeating: "─", count: 50))
print("通过 \(passed) / 失败 \(failed)")
print(failed == 0 ? "✅ 架构验证通过：子进程 + Clash API 路线可行\n"
                  : "❌ 存在失败项，需修正手册架构\n")
exit(failed == 0 ? 0 : 1)
