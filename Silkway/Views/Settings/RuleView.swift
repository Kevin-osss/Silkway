import SwiftUI

/// 设置 → 路由规则：绕过中国大陆 + 自定义直连域名。
struct RuleView: View {
    @State private var store = AppConfigStore.shared
    @State private var ruleSets = RuleSetManager.shared
    @State private var newDomain = ""

    var body: some View {
        Form {
            Section {
                Toggle("绕过中国大陆", isOn: Binding(
                    get: { store.config.bypassChinaMainland },
                    set: { newValue in
                        store.update { $0.bypassChinaMainland = newValue }
                        if newValue && !ruleSets.bypassCNReady {
                            Task { try? await ruleSets.downloadCNRuleSets() }
                        }
                        // 配置变了，热重载生效
                        Task { await SingBoxManager.shared.reloadConfigIfRunning() }
                    }
                ))

                if store.config.bypassChinaMainland {
                    if ruleSets.bypassCNReady {
                        Label("规则集已就绪（geoip-cn + geosite-cn）", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(ColorToken.success)
                    } else if ruleSets.isDownloading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在下载规则集…").font(.caption)
                        }
                        .foregroundStyle(ColorToken.textSecondary)
                    } else if let error = ruleSets.lastError {
                        Label("规则集下载失败：\(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(ColorToken.warning)
                        Button("重试") {
                            Task { try? await ruleSets.downloadCNRuleSets() }
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text("分流")
            } footer: {
                Text("开启后，中国大陆的域名和 IP 直连，其余流量走代理。规则集在首次开启时自动下载。")
                    .font(.caption)
                    .foregroundStyle(ColorToken.textSecondary)
            }

            Section {
                ForEach(Array(store.config.customDirectDomains.enumerated()), id: \.offset) { _, domain in
                    HStack {
                        Image(systemName: "arrow.uturn.right.circle")
                            .foregroundStyle(ColorToken.textSecondary)
                            .font(.caption)
                        Text(domain)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
                .onDelete { offsets in
                    store.update { config in
                        config.customDirectDomains.remove(atOffsets: offsets)
                    }
                    Task { await SingBoxManager.shared.reloadConfigIfRunning() }
                }

                HStack {
                    TextField("添加直连域名（如 .corp.example.com）", text: $newDomain)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addDomain() }
                    Button("添加") { addDomain() }
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("自定义直连域名")
            } footer: {
                Text("这些域名始终直连，不走代理。支持后缀匹配：输入 \".example.com\" 会匹配所有子域名。")
                    .font(.caption)
                    .foregroundStyle(ColorToken.textSecondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addDomain() {
        let domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty else { return }
        store.update { $0.customDirectDomains.append(domain) }
        newDomain = ""
        Task { await SingBoxManager.shared.reloadConfigIfRunning() }
    }
}

#Preview {
    RuleView()
        .frame(width: 600, height: 400)
}
