import Foundation

/// 数字格式化工具。UI 显示统一走这里，禁止各处手写。
enum Formatters {

    /// 实时速率："1.24 MB/s"、"8.61 KB/s"、"0 B/s"。
    /// 设计稿要求人性化单位、保留两位小数。
    static func speed(_ bytesPerSecond: Int64) -> String {
        if bytesPerSecond <= 0 { return "0 B/s" }
        return "\(bytes(bytesPerSecond))/s"
    }

    /// 累计流量 / 连接流量："2.41 MB"、"18.06 MB"、"0.32 MB"。
    static func bytes(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        // 小于 10 用两位小数（1.24），否则一位（18.06 → 18.1？不 —— 设计稿两位）
        return String(format: "%.2f %@", value, units[unit])
    }

    /// 运行时长："02:14:33"。
    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// 单节点延迟显示："42 ms" / "超时" / "—"。
    /// 这是唯一合法的延迟文案来源（手册 5.4：必须走 LatencyBadge 体系）。
    static func latency(_ result: LatencyResult) -> String {
        switch result {
        case .untested:      return "—"
        case .timeout:       return "超时"
        case .value(let ms): return "\(ms) ms"
        }
    }
}
