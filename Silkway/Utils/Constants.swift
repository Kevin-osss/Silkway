import SwiftUI

/// 配色 Token（手册 5.3）。
///
/// ⚠️ 本文件依赖 SwiftUI/AppKit，**不在 SilkwayCore SPM target 内**
/// （Package.swift 已 exclude），否则破坏无头编译。
enum ColorToken {
    // 背景 / 文字：系统语义色，自动适配深浅色
    static let window        = Color(NSColor.windowBackgroundColor)
    static let sidebar       = Color(NSColor.underPageBackgroundColor)
    static let card          = Color(NSColor.controlBackgroundColor)
    static let separator     = Color(NSColor.separatorColor)
    static let textPrimary   = Color(NSColor.labelColor)
    static let textSecondary = Color(NSColor.secondaryLabelColor)

    // 强调色：跟随系统（已定案）
    static let accent = Color.accentColor

    // 状态色：锁定固定值，区分深浅色（手册 5.4）
    static let success  = Color(light: 0x248A3D, dark: 0x32D74B)
    static let warning  = Color(light: 0xB25000, dark: 0xFFD60A)
    static let error    = Color(light: 0xD70015, dark: 0xFF453A)
    static let disabled = Color(NSColor.tertiaryLabelColor)
}

// MARK: - 深浅双色

extension Color {
    /// 按外观自动切换的固定色。状态色专用 —— 强调色不要用这个，用 Color.accentColor。
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(rgb: hex)
        }))
    }
}

extension NSColor {
    /// 按 6 位 RGB hex 创建颜色（alpha 恒为 1.0）。
    ///
    /// ⚠️ 曾经是 argb 实现：`(argb >> 24) & 0xFF` 取 alpha，
    /// 而调用方传的是 6 位 hex（如 0x248A3D），高位是 0 → alpha = 0 全透明，
    /// 导致连接后所有 success 色元素（电源键、延迟徽章）在 UI 上「消失」。
    /// 状态色不需要透明通道，直接锁定 alpha = 1。
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1.0
        )
    }
}

// MARK: - 延迟色阶（手册 5.4 唯一颜色映射点）

extension LatencyLevel {
    var color: Color {
        switch self {
        case .good:     return ColorToken.success
        case .fair:     return ColorToken.warning
        case .poor:     return ColorToken.error
        case .timeout:  return ColorToken.disabled
        case .untested: return ColorToken.disabled
        }
    }
}
