import SwiftUI

/// 快捷控制区：接管方式 / 出站模式 / 当前配置。
///
/// 这三个是日常最高频的操作，原实现在设置面板里，每次切换要开窗口。
/// 参考 ClashX 的做法把它们提到菜单首页，但按 Silkway 的实际能力裁剪：
/// 接管方式只有两种（系统代理 / TUN），用互斥分段而非两个独立开关——
/// 同时开启就是双重代理，之前 SingBoxManager 里专门有互斥约束。
struct QuickControls: View {
    @State private var configStore = AppConfigStore.shared
    @State private var manager = SingBoxManager.shared
    @State private var isSwitching = false

    var body: some View {
        VStack(spacing: 6) {
            takeoverRow
            modeRow
            profileRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 接管方式

    private var takeoverRow: some View {
        ControlRow(label: "接管方式") {
            HStack(spacing: 0) {
                takeoverButton("系统代理", active: !config.tunEnabled)
                takeoverButton("TUN", active: config.tunEnabled)
            }
            .padding(2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func takeoverButton(_ title: String, active: Bool) -> some View {
        Button {
            let wantTUN = title == "TUN"
            guard wantTUN != config.tunEnabled else { return }
            Task { await switchTakeover(toTUN: wantTUN) }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 62)
                .padding(.vertical, 3)
                .background(
                    active ? Color.white.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .foregroundStyle(active ? ColorToken.textPrimary : ColorToken.textSecondary.opacity(0.75))
        }
        .buttonStyle(.plain)
        .disabled(isSwitching)
    }

    /// 切换接管方式 = 改配置 + 重启 sing-box（两种模式的 inbound 结构不同，
    /// 配置改了不重启不会生效）。失败时 lastError 已有原因，UI 显示在状态头。
    private func switchTakeover(toTUN: Bool) async {
        isSwitching = true
        defer { isSwitching = false }
        configStore.update { config in
            config.tunEnabled = toTUN
            config.systemProxyEnabled = !toTUN
        }
        if manager.isRunning {
            await manager.stop()
            try? await manager.start()
        }
    }

    // MARK: 出站模式

    private var modeRow: some View {
        ControlRow(label: "出站模式") {
            HStack(spacing: 0) {
                ForEach(ProxyMode.allCases) { mode in
                    Button {
                        Task { await manager.setMode(mode) }
                    } label: {
                        Text(mode.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 40)
                            .padding(.vertical, 3)
                            .background(
                                manager.mode == mode
                                ? Color.white.opacity(0.18)
                                : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .foregroundStyle(
                                manager.mode == mode
                                ? ColorToken.textPrimary
                                : ColorToken.textSecondary.opacity(0.75)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: 当前配置

    private var profileRow: some View {
        ControlRow(label: "当前配置") {
            Menu {
                Button {
                    switchProfile(to: nil)
                } label: {
                    HStack {
                        Text("节点模式")
                        if config.activeProfileID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(ProfileStore.shared.allProfiles) { profile in
                    Button {
                        switchProfile(to: profile.id)
                    } label: {
                        HStack {
                            Text(profile.name)
                            if config.activeProfileID == profile.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if ProfileStore.shared.allProfiles.isEmpty {
                    Text("没有可用的完整配置")
                        .foregroundStyle(ColorToken.disabled)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(activeProfileName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(ColorToken.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isSwitching)
        }
    }

    private var activeProfileName: String {
        guard let id = config.activeProfileID,
              let profile = ProfileStore.shared.profile(id: id) else {
            return "节点模式"
        }
        return profile.name
    }

    /// 切换配置 = 改 activeProfileID + 重启（出站和路由结构都变了）。
    /// 如果选中的 profile 已被删除（订阅删了但配置没清），回退到节点模式。
    private func switchProfile(to id: UUID?) {
        if let id, ProfileStore.shared.profile(id: id) == nil {
            configStore.update { $0.activeProfileID = nil }
            return
        }
        isSwitching = true
        Task {
            configStore.update { $0.activeProfileID = id }
            if manager.isRunning {
                await manager.stop()
                try? await manager.start()
            }
            isSwitching = false
        }
    }

    private var config: AppConfig { configStore.config }
}

/// 控制行公共骨架：左侧标签 + 右侧控件，垂直居中对齐。
private struct ControlRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(ColorToken.textSecondary)
            Spacer()
            content()
        }
    }
}

#Preview {
    QuickControls()
        .frame(width: 340)
        .padding()
}
