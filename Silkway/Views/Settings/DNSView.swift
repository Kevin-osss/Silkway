import SwiftUI

/// 设置 → DNS：选择 DNS 方案。
///
/// 只提供实战验证过的组合。境外 DoT（tls://8.8.8.8）在国内网络
/// 会被 TLS 握手 RST 导致启动死锁 —— 这是技术验证阶段的真实教训，
/// 所以选项里压根没有它。
struct DNSView: View {
    @State private var store = AppConfigStore.shared

    private let profiles: [(id: String, name: String, detail: String)] = [
        ("system",  "系统默认", "跟随 macOS 系统 DNS（本地网络自动分配，最兼容）"),
        ("ali",     "阿里 DNS", "223.5.5.5（DoH）—— 国内访问快，解析准确"),
        ("tencent", "腾讯 DNS", "119.29.29.29（DoH）—— 国内另一个可靠选择"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(profiles, id: \.id) { profile in
                    HStack {
                        Image(systemName: store.config.dnsProfile == profile.id
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(store.config.dnsProfile == profile.id
                                             ? ColorToken.accent : ColorToken.textSecondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.body)
                            Text(profile.detail)
                                .font(.caption)
                                .foregroundStyle(ColorToken.textSecondary)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.update { $0.dnsProfile = profile.id }
                        Task { await SingBoxManager.shared.reloadConfigIfRunning() }
                    }
                }
            } header: {
                Text("DNS 服务器")
            } footer: {
                Text("DNS 只影响 sing-box 内核解析域名的方式，不影响系统 DNS 设置。修改后如果内核在运行会自动热重载。")
                    .font(.caption)
                    .foregroundStyle(ColorToken.textSecondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    DNSView()
        .frame(width: 600, height: 300)
}
