import SwiftUI

/// 协议类型小标签（设计稿的 ProtocolTag 组件）：SS / VLESS / Trojan / Hysteria2……
struct ProtocolTag: View {
    let proxyProtocol: ProxyProtocol?

    var body: some View {
        if let display = proxyProtocol?.displayName {
            Text(display)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(ColorToken.textSecondary.opacity(0.12), in: Capsule())
                .foregroundStyle(ColorToken.textSecondary)
        }
    }
}

#Preview {
    HStack {
        ProtocolTag(proxyProtocol: .hysteria2)
        ProtocolTag(proxyProtocol: .vless)
        ProtocolTag(proxyProtocol: nil)
    }
    .padding()
}
