import SwiftUI
import Charts

/// 连接日志页：顶部实时流量图，下方活跃连接列表。
///
/// 数据全部来自 SingBoxManager 的 1s 轮询（/connections 端点）。
/// sing-box 未运行时显示空状态。
struct ConnectionView: View {
    @State private var manager = SingBoxManager.shared

    var body: some View {
        Group {
            if !manager.isRunning {
                ContentUnavailableView {
                    Label("内核未运行", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("开启连接后，这里会显示实时连接日志")
                }
            } else {
                VStack(spacing: 0) {
                    TrafficChart(samples: manager.trafficHistory)
                        .frame(height: 90)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    Divider()
                        .padding(.vertical, 8)

                    if manager.connections.isEmpty {
                        Spacer()
                        ContentUnavailableView {
                            Label("暂无活跃连接", systemImage: "arrow.left.arrow.right")
                        } description: {
                            Text("产生网络流量后会出现在这里")
                        }
                        Spacer()
                    } else {
                        connectionList
                    }
                }
            }
        }
    }

    private var connectionList: some View {
        List {
            ForEach(manager.connections) { conn in
                ConnectionRow(connection: conn) {
                    Task { await manager.closeConnection(id: conn.id) }
                }
            }
        }
    }
}

// MARK: - 单行连接

private struct ConnectionRow: View {
    let connection: Connection
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // 第一行：目标地址 + 端口
                HStack(spacing: 6) {
                    Text(connection.host)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    if connection.destinationPort > 0 {
                        Text(":\(connection.destinationPort)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(ColorToken.textSecondary)
                    }
                    Text(connection.network)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(ColorToken.textSecondary.opacity(0.15), in: Capsule())
                }

                // 第二行：规则 + 出站节点 + 流量
                HStack(spacing: 8) {
                    Label(connection.rule, systemImage: "flowchart")
                        .font(.caption2)
                        .foregroundStyle(ColorToken.accent)
                    if let payload = connection.rulePayload {
                        Text(payload)
                            .font(.caption2)
                            .foregroundStyle(ColorToken.textSecondary)
                            .lineLimit(1)
                    }
                    if let outbound = connection.actualOutbound {
                        Label(outbound, systemImage: "globe.asia.australia")
                            .font(.caption2)
                            .foregroundStyle(ColorToken.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(Formatters.bytes(connection.downloadBytes)) ↓ \(Formatters.bytes(connection.uploadBytes)) ↑")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ColorToken.textSecondary)
                }
            }

            // 断开按钮
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(ColorToken.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("断开此连接")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 实时流量图

/// 用 Swift Charts 画最近一分钟的上/下行速率曲线。
/// up 用绿色、down 用蓝色，对应 Clash 系工具的习惯配色。
struct TrafficChart: View {
    let samples: [SingBoxManager.TrafficSample]

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("时间", sample.at),
                    y: .value("速率", sample.down)
                )
                .foregroundStyle(by: .value("方向", "下行"))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("时间", sample.at),
                    y: .value("速率", sample.up)
                )
                .foregroundStyle(by: .value("方向", "上行"))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartForegroundStyleScale([
            "下行": ColorToken.success,
            "上行": ColorToken.accent,
        ])
        .chartYScale(domain: 0...maxY)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(Formatters.speed(bytes))
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
    }

    /// 纵轴上限：取样本最大值的 1.2 倍，留点头部空间；全零时给 1 避免空图。
    private var maxY: Int64 {
        let peak = samples.map(\.down).max() ?? 0
        let peakUp = samples.map(\.up).max() ?? 0
        let max = max(peak, peakUp)
        return max == 0 ? 1 : Int64(Double(max) * 1.2)
    }
}

#Preview {
    ConnectionView()
}
