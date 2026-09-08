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
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("添加订阅")
            }
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
