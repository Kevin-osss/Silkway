import Foundation

/// 规则集（rule-set）下载与缓存管理。
///
/// sing-box 1.12+ 移除了内置 geoip/geosite，必须用 rule_set。
/// 用 **local** 类型而非 remote：
///   - remote 规则集启动时才下载，raw.githubusercontent.com 在国内被墙，
///     下载失败会导致整个启动卡死（手册已记录的真实教训）
///   - local 类型由我们提前下载好，sing-box 只是读文件，启动永远秒开
///
/// 缓存位置：`~/Library/Application Support/Silkway/rulesets/*.srs`
@Observable
@MainActor
final class RuleSetManager {

    static let shared = RuleSetManager()

    /// 规则集状态：nil = 未下载，否则为本地文件路径
    private(set) var geoipCNPath: String?
    private(set) var geositeCNPath: String?

    private(set) var isDownloading = false
    private(set) var lastError: String?

    private let directory: URL
    private let urlSession: URLSession

    init(directory: URL? = nil, urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silkway/rulesets")
        self.directory = dir
        // 检查已有缓存
        let geoip = dir.appendingPathComponent("geoip-cn.srs")
        let geosite = dir.appendingPathComponent("geosite-cn.srs")
        if FileManager.default.fileExists(atPath: geoip.path) { geoipCNPath = geoip.path }
        if FileManager.default.fileExists(atPath: geosite.path) { geositeCNPath = geosite.path }
    }

    /// 「绕过中国大陆」是否可用（两个规则集都就绪）。
    var bypassCNReady: Bool { geoipCNPath != nil && geositeCNPath != nil }

    // MARK: - 下载

    /// 下载地址。优先 jsDelivr 镜像（国内可达性最好），GitHub 原始地址作为备选。
    private static let geoipURLs = [
        "https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs",
        "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
    ]
    private static let geositeURLs = [
        "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs",
        "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
    ]

    /// 下载/更新两个 CN 规则集。
    func downloadCNRuleSets() async throws {
        guard !isDownloading else { return }
        isDownloading = true
        lastError = nil
        defer { isDownloading = false }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            geoipCNPath = try await downloadFirstWorking(Self.geoipURLs, to: "geoip-cn.srs")
            geositeCNPath = try await downloadFirstWorking(Self.geositeURLs, to: "geosite-cn.srs")
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// 依次尝试多个镜像，第一个成功的胜出。
    private func downloadFirstWorking(_ urls: [String], to filename: String) async throws -> String {
        var lastError: Error?
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                // .srs 是二进制 rule-set 格式，至少应有几百字节；太小视为损坏
                guard data.count > 100 else { continue }

                let dest = directory.appendingPathComponent(filename)
                try data.write(to: dest, options: .atomic)
                return dest.path
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? RuleSetError.downloadFailed
    }

    // MARK: - 配置引用

    /// 生成 sing-box 配置的 rule_set 数组（仅在文件就绪时）。
    func ruleSetConfig() -> [[String: Any]] {
        var sets: [[String: Any]] = []
        if let path = geoipCNPath {
            sets.append(["tag": "geoip-cn", "type": "local", "format": "binary", "path": path])
        }
        if let path = geositeCNPath {
            sets.append(["tag": "geosite-cn", "type": "local", "format": "binary", "path": path])
        }
        return sets
    }

    enum RuleSetError: Error {
        case downloadFailed
    }
}
