//
//  UpdateChecker.swift
//  SwallowScreen
//
//  GitHub Releases 更新检查工具（AppPopoverView 与 SettingsView.AboutView 共用）
//

import Foundation

/// 拉取 GitHub Releases latest → 比较版本 → 返回结果，调用方无需重复实现 URLSession 逻辑。
final class UpdateChecker {

    struct UpdateInfo: Equatable {
        let latestVersion: String
        let hasUpdate: Bool
        let downloadURL: String
        // GitHub Release 正文（markdown），供 UI 展示更新内容
        let releaseNotes: String
    }

    enum CheckError: Error {
        case invalidURL
        case network(Error)
        case parseFailed
        // GitHub 403/429 限流——区别于一般网络错误，稍后重试即可
        case rateLimited
        // GitHub 服务端错误（5xx）
        case server(statusCode: Int)
        // Release 未提供可安装的 .dmg/.zip 资产
        case noInstallableAsset
        // 被新的 check 抢占（面板与 AboutView 先后打开都会触发检查）——
        // 被抢占方必须收到回调才能复位 UI，否则永久卡"检查中..."
        case superseded

        /// 检查失败的用户可读文案——调用方 UI 展示的单一来源（与 UpdateStatus.displayText 同模式）
        var userMessage: String {
            switch self {
            case .invalidURL: return "更新地址无效"
            case .rateLimited: return "GitHub 限流，稍后再试"
            case .server(let code): return "服务异常(\(code))"
            case .network: return "网络错误"
            case .parseFailed: return "响应解析失败"
            case .noInstallableAsset: return "未找到安装包"
            case .superseded: return "检查已被新的检查取代"
            }
        }
    }

    /// 5 个 case 对应 UI 状态机：未检查 / 检查中 / 有更新 / 已是最新 / 检查失败
    /// CaseIterable：AppPopoverView 文本槽用全部状态文案做隐藏占位（宽度预留单一来源）
    enum UpdateStatus: CaseIterable {
        case idle
        case checking
        case available
        case upToDate
        case error

        /// 状态机在 UI 上的展示文案——单一来源，AppPopoverView 与 AboutView 共用
        ///（曾两处各自 switch 且文案不一致，抽取后统一）
        var displayText: String {
            switch self {
            case .idle, .error: return "检查更新"
            case .checking: return "检查中..."
            case .available: return "发现新版本"
            case .upToDate: return "已是最新"
            }
        }

        /// 按钮文案的最终展示规则（AppPopoverView 与 AboutView 共用的单一来源）：
        /// error 态优先显示具体失败原因（如「GitHub 限流，稍后再试」），无原因时回落默认文案
        func displayText(failureReason: String) -> String {
            if self == .error && !failureReason.isEmpty { return failureReason }
            return displayText
        }
    }

    static let shared = UpdateChecker()

    private static let apiURL = URL(string: "https://api.github.com/repos/Qithking/SwallowScreen/releases/latest")!
    private static let currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    private let session: URLSession
    private var task: URLSessionDataTask?

    // ephemeral 配置：禁用磁盘缓存，减少内存占用（URLSession.shared 默认会缓存响应到磁盘和内存）
    private static let ephemeralSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private init(session: URLSession = ephemeralSession) {
        self.session = session
    }

    // 当前进行中检查的 completion——被新 check 抢占时以 superseded 回调旧方，
    // 否则旧方 UI 永久卡在 checking 态（completion 被 cancelled 分支静默过滤）
    private var activeCompletion: ((Result<UpdateInfo, CheckError>) -> Void)?

    /// 主动取消正在进行的 check（completion 会以 NSURLErrorCancelled 被回调，check 内部已静默过滤）
    func cancel() {
        task?.cancel()
        task = nil
        // 清空 activeCompletion：主动取消方 UI 自行复位，悬挂的旧 completion
        // 不应在未来某次 check 抢占时被误回调
        activeCompletion = nil
    }

    /// 异步执行更新检查。completion 始终在主线程上调用。
    /// 同实例再次 check 会自动取消前一个 task，并以 superseded 通知被抢占方
    func check(completion: @escaping (Result<UpdateInfo, CheckError>) -> Void) {
        task?.cancel()
        activeCompletion?(.failure(.superseded))
        // 登记当前 completion（check 在主线程调用，与抢占回调同线程无并发问题）：
        // 下一次 check 抢占时以 superseded 回调本方
        activeCompletion = completion

        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        task = session.dataTask(with: request) { data, response, error in
            let deliver: (Result<UpdateInfo, CheckError>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error = error {
                // 主动 cancel / 被新 check 抢占时 task 会以 NSURLErrorCancelled 回调，
                // 此时不向调用方报「检查失败」（调用方 UI 会误显示错误态）
                if (error as? URLError)?.code == .cancelled || (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                deliver(.failure(.network(error)))
                return
            }
            guard let data = data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                // 区分限流/服务端错误——一律归 parseFailed 会让用户无从判断（限流稍后再试即可）
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 403 || http.statusCode == 429 {
                        deliver(.failure(.rateLimited))
                    } else if http.statusCode >= 500 {
                        deliver(.failure(.server(statusCode: http.statusCode)))
                    } else {
                        deliver(.failure(.parseFailed))
                    }
                } else {
                    deliver(.failure(.parseFailed))
                }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                deliver(.failure(.parseFailed))
                return
            }
            let raw = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            // 剥离预发布后缀（如 1.0.2-rc.1 → 1.0.2）再比较——numeric 比较会把后缀串
            // 误判为更大版本；预发布段不参与"是否有更新"判定，latestVersion 仍显示完整 tag
            let baseVersion = raw.split(separator: "-", maxSplits: 1).first.map(String.init) ?? raw
            // 数值化字符串比较：1.2.10 > 1.2.9（普通字符串比较会误判）
            let hasUpdate = baseVersion.compare(Self.currentVersion, options: .numeric) == .orderedDescending
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
            guard !hasUpdate || !downloadURL.isEmpty else {
                // 有更新但 Release 未提供可安装资产——空 URL 按 success 返回会让
                // 下载窗口拿到空地址，必须显式失败
                deliver(.failure(.noInstallableAsset))
                return
            }
            deliver(.success(UpdateInfo(
                latestVersion: raw,
                hasUpdate: hasUpdate,
                downloadURL: downloadURL,
                // Release 正文（markdown）可空；markdown 渲染是展示层职责，这里透传原文
                releaseNotes: json["body"] as? String ?? ""
            )))
        }
        task?.resume()
    }
}
