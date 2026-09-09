import Foundation
import Observation

/// 完整配置（ImportedProfile）的持久化存储。
///
/// 与 ProxyNodeStore 平行：subscriptions/nodes 管「节点订阅」，
/// profiles 管「自带策略组与规则的完整配置」。
/// 状态单一来源原则同 ProxyNodeStore —— View 只读，写入走这里的方法。
@Observable
@MainActor
final class ProfileStore {

    static let shared = ProfileStore()

    private(set) var profiles: [ImportedProfile] = []

    private let directory: URL

    private var profilesURL: URL { directory.appendingPathComponent("profiles.json") }

    /// 目录可注入：测试用临时目录，App 用真实 Application Support。
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Silkway/store", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.directory = dir
        }
        load()
    }

    // MARK: - 查询

    var allProfiles: [ImportedProfile] { profiles }

    func profile(id: UUID) -> ImportedProfile? {
        profiles.first { $0.id == id }
    }

    func profile(forSubscription subscriptionID: UUID) -> ImportedProfile? {
        profiles.first { $0.subscriptionID == subscriptionID }
    }

    // MARK: - 写入

    func saveProfile(_ profile: ImportedProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    /// 移除某订阅关联的全部配置（订阅删除时调用）。
    func removeProfiles(forSubscription subscriptionID: UUID) {
        profiles.removeAll { $0.subscriptionID == subscriptionID }
        persist()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: profilesURL),
              let decoded = try? JSONDecoder().decode([ImportedProfile].self, from: data)
        else { return }
        profiles = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: profilesURL, options: .atomic)
    }
}
