import Foundation

/// 应用设置的持久化存储。
///
/// AppConfig 只有十几个标量字段，用单个 JSON 文件足够
/// （手册 §4 只禁止 UserDefaults 存大量节点数据；配置文件无此限制，
/// 但为了和 ProxyNodeStore 风格一致、便于测试，同样用 JSON 文件）。
///
/// 存储位置：`~/Library/Application Support/Silkway/store/appconfig.json`
@Observable
@MainActor
final class AppConfigStore {

    static let shared = AppConfigStore()

    private(set) var config: AppConfig

    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silkway/store")
        self.fileURL = dir.appendingPathComponent("appconfig.json")

        // 加载：失败则用默认值（首次启动或文件损坏）
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode(AppConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = AppConfig()
        }
    }

    /// 修改并立即持久化。
    func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
