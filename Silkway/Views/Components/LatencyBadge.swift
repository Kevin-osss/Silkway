import SwiftUI

/// 延迟标签。所有显示延迟的地方必须用这个组件（手册 5.4）。
struct LatencyBadge: View {
    let result: LatencyResult

    var body: some View {
        Text(Formatters.latency(result))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(result.level.color)
    }
}

#Preview {
    HStack(spacing: 16) {
        LatencyBadge(result: .value(42))
        LatencyBadge(result: .value(238))
        LatencyBadge(result: .value(512))
        LatencyBadge(result: .timeout)
        LatencyBadge(result: .untested)
    }
    .padding()
}
