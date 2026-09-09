import SwiftUI

/// 设置面板的订阅管理页。
///
/// 功能：添加订阅（名称 + URL）、手动更新、删除、显示节点数和上次更新时间。
/// 自动更新间隔的设置留给后续版本（先固定每日检查）。
struct SubscriptionView: View {
    @State private var manager = SubscriptionManager.shared
    @State private var showingAddSheet = false
    @State private var updatingID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if manager.subscriptions.isEmpty {
                    ContentUnavailableView {
                        Label("还没有订阅", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("添加一个订阅链接，Silkway 会自动拉取节点列表")
                    } actions: {
                        Button("添加订阅") { showingAddSheet = true }
                    }
                } else {
                    List {
                        ForEach(manager.subscriptions) { sub in
                            SubscriptionRow(
                                subscription: sub,
                                nodeCount: manager.allNodes.filter { $0.subscriptionID == sub.id }.count,
                                isUpdating: updatingID == sub.id
                            ) {
                                await refresh(subscription: sub)
                            }
                        }
                        .onDelete(perform: delete)

                        Section("高级") {
                            UserAgentField()
                        }
                    }
                }
            }
            // 空状态下 ContentUnavailableView 不一定擑满高度，
            // 不显式擑满的话底部按钮条会贴在内容正下方而不是窗口底部
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // 按钮放页面底部而不是窗口 toolbar：设置窗口的 Tab 栏就是 toolbar本身，
            // 子页注册的 ToolbarItem 会被合并进去且不随 Tab 切换清除，
            // 造成「每个 Tab 都有个 + 号，点了没反应」（2026-09-09 实测）。
            HStack {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加订阅", systemImage: "plus")
                }
                .help("添加机场订阅链接")

                Spacer()

                if !manager.subscriptions.isEmpty {
                    Text("\(manager.subscriptions.count) 个订阅")
                        .font(.caption)
                        .foregroundStyle(ColorToken.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSubscriptionSheet { name, url in
                await addSubscription(name: name, url: url)
            }
        }
        .alert("订阅错误", isPresented: .constant(errorMessage != nil)) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // 打开页面时顺带刷新已过期的订阅
        .task {
            await manager.updateAllDue()
        }
    }

    private func refresh(subscription: Subscription) async {
        updatingID = subscription.id
        defer { updatingID = nil }
        do {
            _ = try await manager.updateSubscription(id: subscription.id)
            // 节点可能变了，热重载内核配置
            await SingBoxManager.shared.reloadConfigIfRunning()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addSubscription(name: String, url: URL) async {
        do {
            _ = try await manager.addSubscription(name: name, url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            manager.deleteSubscription(id: manager.subscriptions[index].id)
        }
    }
}

// MARK: - 单个订阅行

private struct SubscriptionRow: View {
    let subscription: Subscription
    let nodeCount: Int
    let isUpdating: Bool
    let onRefresh: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(subscription.name)
                    .font(.headline)
                Text(subscription.maskedURL)
                    .font(.caption)
                    .foregroundStyle(ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // lineLimit 只管显示截断，不管布局诉求：
                    // 这行的理想宽度仍是整条 URL 的长度，会向上顶宽窗口。
                    // 显式封顶才能断开这条传播链。
                    .frame(maxWidth: 420, alignment: .leading)

                HStack(spacing: 8) {
                    Label("\(nodeCount) 个节点", systemImage: "point.3.connected.trianglepath.dotted")
                    if let updated = subscription.lastUpdated {
                        Text("更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("从未更新")
                    }
                }
                .font(.caption2)
                .foregroundStyle(ColorToken.textSecondary)

                if let error = subscription.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(ColorToken.warning)
                }

                // 被跳过的条目必须可见：否则用户面对「机场说 80 个节点，
                // 这里只有 52 个」无从判断是自己的错还是机场的错
                if let skipped = subscription.skippedCount, skipped > 0 {
                    Label("\(skipped) 个条目未导入", systemImage: "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(ColorToken.warning)
                        .help(subscription.skippedReasons?.joined(separator: "\n") ?? "")
                }

                TrafficBar(subscription: subscription)
            }

            Spacer()

            Button {
                Task { await onRefresh() }
            } label: {
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("立即更新")
            .disabled(isUpdating)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - User-Agent 设置

/// 机场根据 UA 返回不同格式的订阅内容，有些甚至只认特定客户端。
/// 拉不到节点时换一个 UA 往往就好了，所以开放给用户改。
private struct UserAgentField: View {
    @State private var store = AppConfigStore.shared
    @State private var text: String = AppConfigStore.shared.config.subscriptionUserAgent

    private static let presets = [
        "sing-box/1.13.19",
        "clash-verge/v1.5.11",
        "ClashforWindows/0.19.23",
        "v2rayN/6.23",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("User-Agent")
                Spacer()
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(save)

                Menu {
                    ForEach(Self.presets, id: \.self) { preset in
                        Button(preset) {
                            text = preset
                            save()
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            Text("机场按 UA 返回不同格式。拉不到节点时可换成 clash 或 v2rayN 试试。")
                .font(.caption2)
                .foregroundStyle(ColorToken.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            text = store.config.subscriptionUserAgent
            return
        }
        store.update { $0.subscriptionUserAgent = trimmed }
    }
}

// MARK: - 流量与到期

/// 机场在 Subscription-Userinfo 响应头里返回的流量/到期信息。
/// 没返回这个头的机场就不显示（而不是显示 0）—— “未知”和“用完了”是两回事。
private struct TrafficBar: View {
    let subscription: Subscription

    var body: some View {
        if let used = subscription.trafficUsed {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let total = subscription.trafficTotal, total > 0 {
                        Text("\(Formatters.bytes(used)) / \(Formatters.bytes(total))")
                    } else {
                        Text("已用 \(Formatters.bytes(used))・不限量")
                    }

                    if let days = subscription.daysUntilExpiry() {
                        Text("·")
                        Text(days >= 0 ? "\(days) 天后到期" : "已过期")
                            .foregroundStyle(days <= 7 ? ColorToken.warning : ColorToken.textSecondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(ColorToken.textSecondary)

                if let ratio = subscription.trafficRatio {
                    ProgressView(value: ratio)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                        .tint(ratio > 0.9 ? ColorToken.error : ColorToken.accent)
                }
            }
        }
    }
}

// MARK: - 添加订阅弹窗

private struct AddSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// 父级提供的保存回调，成功时自己 dismiss。
    let onSave: (String, URL) async -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("添加订阅")
                .font(.headline)

            Form {
                TextField("名称（如：主力机场）", text: $name)
                TextField("订阅链接 https://…", text: $urlString)
                    .textContentType(.URL)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ColorToken.warning)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("添加") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || urlString.isEmpty || isSaving)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() async {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "请输入有效的 http(s) 链接"
            return
        }
        isSaving = true
        await onSave(name.trimmingCharacters(in: .whitespaces), url)
        isSaving = false
        dismiss()
    }
}

#Preview {
    SubscriptionView()
}
