import SwiftUI

/// 设置 → 代理节点：全部节点总览（按订阅分组）+ 手动添加单节点。
///
/// 与菜单栏弹窗的分工：菜单栏管「选哪个」，这里管「有哪些」——
/// 总览、搜索、手动补充订阅里没有的节点。
struct ProxyView: View {
    @State private var manager = SubscriptionManager.shared
    @State private var singBox = SingBoxManager.shared
    @State private var searchText = ""
    @State private var showingAddSheet = false

    /// 手动添加的节点放在内存里的"手动"分组，subscriptionID 为 nil。
    private var manualNodes: [ProxyNode] {
        filtered(manager.allNodes.filter { $0.subscriptionID == nil })
    }

    private func nodes(for subscription: Subscription) -> [ProxyNode] {
        filtered(manager.allNodes.filter { $0.subscriptionID == subscription.id })
    }

    private func filtered(_ nodes: [ProxyNode]) -> [ProxyNode] {
        guard !searchText.isEmpty else { return nodes }
        return nodes.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.server.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if manager.allNodes.isEmpty {
                    ContentUnavailableView {
                        Label("还没有节点", systemImage: "globe.asia.australia")
                    } description: {
                        Text("在「订阅」页添加订阅，或手动粘贴节点链接")
                    } actions: {
                        Button("手动添加节点") { showingAddSheet = true }
                    }
                } else {
                    VStack(spacing: 0) {
                        // 搜索框画在内容区而不用 .searchable：
                        // 设置窗口的 Tab 栏就是窗口 toolbar，.searchable 会把搜索框
                        // 注入同一条 toolbar，和 Tab 图标抢位置 → 挤成「搜索框 + 下方小字」
                        // 的畸形布局，还会顶歪 Tab 图标（2026-09-09 实测）。
                        SearchField(text: $searchText, prompt: "搜索节点名或服务器")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                        Divider()

                        List {
                            if !manualNodes.isEmpty {
                                Section("手动添加 (\(manualNodes.count))") {
                                    ForEach(manualNodes) { NodeOverviewRow(node: $0) }
                                }
                            }
                            ForEach(manager.subscriptions) { sub in
                                let nodes = nodes(for: sub)
                                if !nodes.isEmpty {
                                    Section("\(sub.name) (\(nodes.count))") {
                                        ForEach(nodes) { NodeOverviewRow(node: $0) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // 空状态下 ContentUnavailableView 不一定擑满高度，
            // 不显式擑满的话底部按钮条会贴在内容正下方而不是窗口底部
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // 动作按钮放页面底部而不是窗口 toolbar：
            // 子页注册的 ToolbarItem 会被合并进唯一的窗口 toolbar，且不随 Tab 切换清除 ——
            // 结果是每个 Tab 都看得到别的页的按钮，而它的 sheet 挂在未渲染的视图上，
            // 点下去没任何反应。
            HStack {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("手动添加节点", systemImage: "plus")
                }
                .help("粘贴 ss:// vmess:// 等节点链接")

                Spacer()

                if !manager.allNodes.isEmpty {
                    Text("共 \(manager.allNodes.count) 个节点")
                        .font(.caption)
                        .foregroundStyle(ColorToken.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddNodeSheet()
        }
    }
}

// MARK: - 搜索框

/// 内容区搜索框。
///
/// 不用 `.searchable`（会注入窗口 toolbar，和 Tab 栏抢位置）。
/// 也不用自绘背景圆角——SwiftUI 的 `.roundedBorder` TextField 就是
/// macOS 系统搜索框样式（Kit Search Fields/3 Rg 规格：120x24pt，
/// 系统会自动绘制边框、焦点环、清空按钮）。
/// 只需加放大镜图标前缀。
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(ColorToken.textSecondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // 系统搜索框的容器样式：controlBackgroundColor 背景 + 圆角 + 边框
        // 自绘边框会和系统焦点环冲突，用系统样式就不会
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - 节点总览行

private struct NodeOverviewRow: View {
    let node: ProxyNode
    @State private var singBox = SingBoxManager.shared

    var body: some View {
        HStack(spacing: 10) {
            CountryFlagView(countryCode: node.countryCode)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text("\(node.server):\(node.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ColorToken.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            ProtocolTag(proxyProtocol: node.proxyProtocol)

            // 延迟：优先实时测速结果，其次持久化的旧值
            latencyBadge
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var latencyBadge: some View {
        if let result = singBox.latencyByTag[node.name] {
            LatencyBadge(result: result)
        } else if let ms = node.latency {
            LatencyBadge(result: .value(ms))
        } else if node.hasBeenTested {
            LatencyBadge(result: .timeout)
        } else {
            LatencyBadge(result: .untested)
        }
    }
}

// MARK: - 手动添加节点弹窗

private struct AddNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var uriText = ""
    @State private var errorMessage: String?
    @State private var previewNodes: [ProxyNode] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("手动添加节点")
                .font(.headline)

            Text("粘贴节点链接，支持 vmess:// vless:// trojan:// ss:// hysteria2://，每行一个")
                .font(.caption)
                .foregroundStyle(ColorToken.textSecondary)

            TextEditor(text: $uriText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 100)
                .border(ColorToken.separator)

            // 实时解析预览
            if !previewNodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("将添加 \(previewNodes.count) 个节点：")
                        .font(.caption)
                        .foregroundStyle(ColorToken.success)
                    ForEach(previewNodes.prefix(5)) { node in
                        Text("• \(node.name) (\(node.proxyProtocol.displayName))")
                            .font(.caption2)
                    }
                    if previewNodes.count > 5 {
                        Text("… 等 \(previewNodes.count) 个")
                            .font(.caption2)
                            .foregroundStyle(ColorToken.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ColorToken.error)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("添加") { addNodes() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)  // 系统主按钮样式（Kit Bordered Default）
                    .disabled(previewNodes.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: uriText) { _, newValue in
            let parsed = SubscriptionParser.parse(newValue)
            // 手动添加的节点不带订阅归属
            previewNodes = parsed
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsed.isEmpty {
                errorMessage = "无法识别节点链接格式"
            } else {
                errorMessage = nil
            }
        }
    }

    private func addNodes() {
        // 手动节点存入 ProxyNodeStore，subscriptionID = nil
        for node in previewNodes {
            ProxyNodeStore.shared.addManualNode(node)
        }
        // 如果内核在跑，热重载让新节点立即可选
        Task { await SingBoxManager.shared.reloadConfigIfRunning() }
        dismiss()
    }
}

#Preview {
    ProxyView()
        .frame(width: 600, height: 500)
}
