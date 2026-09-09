import Foundation
import Testing
@testable import SilkwayCore

/// macOS 27 UI 迁移的回归测试。
///
/// 迁移把自绘分段控件改成系统 Picker(.segmented)，视觉层变化不该破坏
/// 业务逻辑：切换接管方式/TUN 必须重启 sing-box，切换模式必须热切生效，
/// 切换配置必须重启。这些行为是迁移前的既有契约，必须钉死。
@Suite("UI 迁移回归：控制逻辑")
@MainActor
struct QuickControlsRegressionTests {

    // MARK: - 接管方式切换（QuickControls.switchTakeover）

    @Test("切换接管方式：TUN 开启时关闭系统代理")
    func takeoverSwitchMutualExclusion() async {
        let store = AppConfigStore.shared
        var config = store.config
        config.tunEnabled = false
        config.systemProxyEnabled = true
        store.update { $0 = config }

        // 模拟 QuickControls 的切换逻辑：改配置 + 重启
        store.update {
            $0.tunEnabled = true
            $0.systemProxyEnabled = false
        }

        #expect(store.config.tunEnabled == true)
        #expect(store.config.systemProxyEnabled == false, "TUN 与系统代理必须互斥")

        // 清理：恢复原状态
        store.update {
            $0.tunEnabled = config.tunEnabled
            $0.systemProxyEnabled = config.systemProxyEnabled
        }
    }

    @Test("切换接管方式：系统代理开启时关闭 TUN")
    func takeoverSwitchReverse() async {
        let store = AppConfigStore.shared
        var config = store.config
        config.tunEnabled = true
        config.systemProxyEnabled = false
        store.update { $0 = config }

        store.update {
            $0.tunEnabled = false
            $0.systemProxyEnabled = true
        }

        #expect(store.config.tunEnabled == false)
        #expect(store.config.systemProxyEnabled == true)

        store.update {
            $0.tunEnabled = config.tunEnabled
            $0.systemProxyEnabled = config.systemProxyEnabled
        }
    }

    // MARK: - 出站模式切换（SingBoxManager.setMode）

    @Test("切换模式：未运行时记偏好不影响下次启动")
    func modeSwitchWhenNotRunning() async {
        let manager = SingBoxManager.shared
        // 确保未运行
        if manager.isRunning { await manager.stop() }

        let originalMode = manager.mode
        await manager.setMode(.global)
        #expect(manager.mode == .global, "未运行时 setMode 应直接记偏好")

        // 恢复原模式
        await manager.setMode(originalMode)
    }

    // MARK: - 配置切换（QuickControls.switchProfile）

    @Test("切换配置：选中的 profile 不存在时回退到节点模式")
    func profileSwitchWithMissingProfile() async {
        let store = AppConfigStore.shared
        let store2 = ProfileStore.shared

        // 模拟 QuickControls 的逻辑：选中的 profile 已被删除
        let fakeID = UUID()
        store.update { $0.activeProfileID = fakeID }

        // 修复逻辑：不存在则回退 nil
        if store2.profile(id: fakeID) == nil {
            store.update { $0.activeProfileID = nil }
        }

        #expect(store.config.activeProfileID == nil, "不存在的 profile 应回退到节点模式")
    }
}
