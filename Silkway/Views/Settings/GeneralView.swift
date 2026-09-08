import SwiftUI
import ServiceManagement

/// 设置 → 通用：启动行为、代理模式、端口信息。
struct GeneralView: View {
    @State private var store = AppConfigStore.shared
    @State private var manager = SingBoxManager.shared
    @State private var loginItemStatus: String = ""
    @State private var loginItemError: String?
    @State private var tunGuidance: String?

    var body: some View {
        Form {
            Section("启动") {
                Toggle("开机自动启动", isOn: Binding(
                    get: { store.config.launchAtLogin },
                    set: { newValue in setLaunchAtLogin(newValue) }
                ))
                if let loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ColorToken.warning)
                }
                if !loginItemStatus.isEmpty {
                    Text(loginItemStatus)
                        .font(.caption2)
                        .foregroundStyle(ColorToken.textSecondary)
                }

                Toggle("启动后自动连接", isOn: Binding(
                    get: { store.config.autoConnectOnLaunch },
                    set: { newValue in store.update { $0.autoConnectOnLaunch = newValue } }
                ))

                Toggle("菜单栏显示实时速率", isOn: Binding(
                    get: { store.config.showSpeedInMenuBar },
                    set: { newValue in store.update { $0.showSpeedInMenuBar = newValue } }
                ))
            }

            Section("代理模式") {
                Toggle("接管系统代理（HTTP/HTTPS/SOCKS）", isOn: Binding(
                    get: { store.config.systemProxyEnabled },
                    set: { newValue in
                        store.update { $0.systemProxyEnabled = newValue }
                        // 与 TUN 互斥（手册 §AppConfig 注释）
                        if newValue { store.update { $0.tunEnabled = false } }
                    }
                ))
                .disabled(store.config.tunEnabled)

                Toggle("TUN 模式（全局接管，需授权）", isOn: Binding(
                    get: { store.config.tunEnabled },
                    set: { newValue in
                        if newValue && !TunManager.shared.isAvailable {
                            tunGuidance = "TUN 模式需要先把 Silkway.app 拖入「应用程序」文件夹"
                            return
                        }
                        store.update { $0.tunEnabled = newValue }
                        if newValue {
                            store.update { $0.systemProxyEnabled = false }
                            // 已连接时切换模式需要重启内核
                            if manager.isRunning {
                                Task { try? await manager.restart() }
                            }
                        }
                    }
                ))
                .help("TUN 模式通过虚拟网卡接管全部流量，需要系统授权")

                if let tunGuidance {
                    Label(tunGuidance, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ColorToken.warning)
                }
                if store.config.tunEnabled && TunManager.shared.status == .requiresApproval {
                    HStack(spacing: 8) {
                        Label("需要批准后台运行", systemImage: "hand.raised.fill")
                            .font(.caption)
                            .foregroundStyle(ColorToken.warning)
                        Button("打开系统设置") {
                            TunManager.shared.openSystemSettings()
                        }
                        .font(.caption)
                    }
                }
            }

            Section("端口") {
                LabeledContent("混合入站", value: manager.isRunning ? "127.0.0.1:\(manager.currentMixedPort)" : "未运行")
                LabeledContent("Clash API", value: manager.isRunning ? "127.0.0.1:\(manager.currentAPIPort)" : "未运行")
            }
            .font(.system(.body, design: .monospaced))
        }
        .formStyle(.grouped)
        .onAppear { refreshLoginItemStatus() }
    }

    // MARK: - 开机自启

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        store.update { $0.launchAtLogin = enabled }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = "开机自启设置失败：\(error.localizedDescription)"
            // 回滚配置
            store.update { $0.launchAtLogin = !enabled }
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginItemStatus = "已启用"
        case .requiresApproval: loginItemStatus = "需在「系统设置 → 登录项」中批准"
        case .notRegistered: loginItemStatus = ""
        case .notFound: loginItemStatus = ""
        @unknown default: loginItemStatus = ""
        }
    }
}

#Preview {
    GeneralView()
        .frame(width: 600, height: 400)
}
