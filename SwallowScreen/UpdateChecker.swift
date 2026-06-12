//
//  UpdateChecker.swift
//  SwallowScreen
//
//  统一的 GitHub Releases 更新检查工具（被 AppPopoverView 与 SettingsView.AboutView 共用）
//

import Foundation

/// T14: 把"拉取 GitHub Releases latest → 比较版本 → 返回结果"统一到一个工具类。
/// 调用方只需关心结果，不需重复实现 URLSession + JSONSerialization 逻辑。
final class UpdateChecker {

    struct UpdateInfo: Equatable {
        let latestVersion: String
        let hasUpdate: Bool
        let downloadURL: String
    }

    enum CheckError: Error {
        case invalidURL
        case network(Error)
        case parseFailed
    }

    /// RT106: UpdateStatus 抽到 UpdateChecker 统一引用——AppPopoverView 与 SettingsView.AboutView 共用
    /// 5 个 case 对应 UI 状态机：未检查 / 检查中 / 有更新 / 已是最新 / 检查失败
    enum UpdateStatus {
        case idle
        case checking
        case available
        case upToDate
        case error
    }

    static let shared = UpdateChecker()

    private static let apiURL = URL(string: "https://api.github.com/repos/Qithking/SwallowScreen/releases/latest")!
    private static let currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    private let session: URLSession
    private var task: URLSessionDataTask?

    private init(session: URLSession = .shared) {
        self.session = session
    }

    /// RT11: 主动取消正在进行的 check（不会调用其 completion）
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 异步执行更新检查。completion 始终在主线程上调用。
    /// 返回 nil 表示已是最新或解析失败（调用方按 UI 决定如何展示）。
    /// RT11: 同实例再次 check 会自动取消前一个 task
    func check(completion: @escaping (Result<UpdateInfo, CheckError>) -> Void) {
        // RT11: 取消上一次未完成的请求
        task?.cancel()

        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        task = session.dataTask(with: request) { data, response, error in
            // 主线程交付
            let deliver: (Result<UpdateInfo, CheckError>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error = error {
                deliver(.failure(.network(error)))
                return
            }
            guard let data = data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                deliver(.failure(.parseFailed))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                deliver(.failure(.parseFailed))
                return
            }
            let raw = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            // RT122: 用 Foundation 数值化字符串比较（1.2.10 > 1.2.9）；原字符串相等比较会误判
            let hasUpdate = raw.compare(Self.currentVersion, options: .numeric) == .orderedDescending
            let downloadURL: String
            if let assets = json["assets"] as? [[String: Any]] {
                // 优先匹配 .dmg / .zip 安装包，避免取到 .sha256 校验文件或源码 tarball
                let installExtensions = [".dmg", ".zip"]
                let matchedAsset = assets.first(where: { asset in
                    guard let url = asset["browser_download_url"] as? String else { return false }
                    return installExtensions.contains(where: { url.hasSuffix($0) })
                }) ?? assets.first
                downloadURL = (matchedAsset?["browser_download_url"] as? String) ?? ""
            } else {
                downloadURL = ""
            }
            deliver(.success(UpdateInfo(latestVersion: raw, hasUpdate: hasUpdate, downloadURL: downloadURL)))
        }
        task?.resume()
    }
}
