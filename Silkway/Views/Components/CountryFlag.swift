import SwiftUI

/// 国家码 → Emoji 国旗。设计稿节点行左侧的国旗。
enum CountryFlag {

    /// "HK" → "🇭🇰"。无效码返回 nil，UI 应隐藏国旗位。
    static func emoji(for code: String?) -> String? {
        guard let code, code.count == 2 else { return nil }
        let scalars = code.uppercased().unicodeScalars
        // 区域指示符号 A-Z 是 U+1F1E6..U+1F1FF
        let base: UInt32 = 0x1F1E6 - 65
        guard scalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
        return String(String.UnicodeScalarView(scalars.map { Unicode.Scalar(base + $0.value)! }))
    }
}

/// 国旗视图。无国家码时显示透明占位，保持行对齐。
struct CountryFlagView: View {
    let countryCode: String?

    var body: some View {
        Group {
            if let emoji = CountryFlag.emoji(for: countryCode) {
                Text(emoji)
            } else {
                Color.clear.frame(width: 18, height: 14)
            }
        }
        .font(.system(size: 14))
    }
}

#Preview {
    HStack {
        CountryFlagView(countryCode: "HK")
        CountryFlagView(countryCode: "JP")
        CountryFlagView(countryCode: nil)
    }
    .padding()
}
