//
//  DownloadWindow.swift
//  SwallowScreen
//
//  下载窗口视图 - 显示下载进度
//

import SwiftUI
import AppKit
import os.log
// SPM 构建下 UpdateDownloadPersistence 位于 SwallowScreenCore 模块（SPM 自动定义 SWIFT_PACKAGE）；
// Xcode 工程为平面 target 无需 import（与 AppSettings.swift 同模式）
#if SWIFT_PACKAGE
import SwallowScreenCore
#endif

// MARK: - 下载窗口控制器
/// 单例 + 复用窗口，重复触发时聚焦已有窗口
/// 显式 @MainActor，与 macOS 14+ NSWindowController 隔离保证一致
@MainActor
class DownloadWindowController: NSWindowController {
    static let shared = DownloadWindowController()

    // 单例 init 的初始窗口
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "下载更新"
        window.setContentSize(NSSize(width: 420, height: 170))
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }

    private init() {
        super.init(window: Self.makeWindow())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 打开或聚焦下载窗口
    func showWindow() {
        if let w = window, !w.isVisible {
            w.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 封装"创建 contentViewController + 替换 + showWindow"流程
    static func open(version: String, downloadURL: URL) {
        let controller = DownloadWindowController.shared
        guard let window = controller.window else {
            os_log("DownloadWindowController.window 为 nil，无法打开下载窗口",
                   log: OSLog.default, type: .error)
            return
        }
        let hostingController = NSHostingController(
            rootView: DownloadWindowContentView(version: version, downloadURL: downloadURL)
        )
        window.contentViewController = hostingController
        controller.showWindow()
    }
}

// MARK: - 下载窗口内容视图
struct DownloadWindowContentView: View {
    let version: String
    let downloadURL: URL

    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: DownloadStatus = .downloading
    @State private var errorMessage: String = ""
    // 下载完成后保存文件 URL，供"安装并重启"使用
    @State private var downloadedFileURL: URL?

    // 持有对自己窗口的弱引用，避免 closeWindow 误关其他窗口
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var windowRef: NSWindow?

    enum DownloadStatus {
        case downloading
        case completed
        case failed
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if let appIcon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .cornerRadius(10)
                } else {
                    Image("AppIcon")
                        .resizable()
                        .frame(width: 48, height: 48)
                        .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 6) {
                    // 复用已完成下载（completedFile 命中）时状态为 completed，
                    // 标题仍写死"正在下载"会与右侧"下载完成"状态自相矛盾
                    Text(downloadStatus == .completed ? "下载完成 v\(version)" : "正在下载 v\(version)")
                        .font(.headline)

                    if downloadStatus == .downloading {
                        VStack(alignment: .leading, spacing: 3) {
                            if downloadProgress < 0 {
                                // 服务器未返回总大小（无 Content-Length）——转圈不确定态，
                                // 无从计算百分比与进度条
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                ProgressView(value: downloadProgress)
                                    .progressViewStyle(.linear)
                                    .frame(height: 8)

                                Text("\(Int(downloadProgress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } else if downloadStatus == .completed {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("下载完成")
                                .foregroundColor(.green)
                        }
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if downloadStatus == .failed {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("下载失败")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }

                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    } else if downloadStatus == .downloading {
                        Text("正在下载更新文件...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if downloadStatus == .completed {
                        Text("下载完成，点击安装并重启以更新应用")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if downloadStatus == .downloading {
                        Button(action: cancelDownload) {
                            Text("取消")
                                .frame(minWidth: 60)
                        }
                        .buttonStyle(.bordered)
                    } else if downloadStatus == .failed {
                        Button(action: copyDownloadLink) {
                            Label("复制链接", systemImage: "doc.on.doc")
                                .frame(minWidth: 80)
                        }
                        .buttonStyle(.bordered)

                        Button(action: startDownload) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .frame(minWidth: 60)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if downloadStatus == .completed {
                        Button(action: openDownloadedFile) {
                            Text("稍后安装")
                                .frame(minWidth: 70)
                        }
                        .buttonStyle(.bordered)

                        Button(action: installAndRelaunch) {
                            Label("安装并重启", systemImage: "arrow.triangle.2.circlepath")
                                .frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 380, height: 140)
        .background(
            // 抓取宿主 NSWindow 存到 @State，关闭时直接 close 自己
            GeometryReader { _ in
                WindowAccessor { window in
                    if windowRef !== window {
                        windowRef = window
                    }
                }
            }
        )
        .onAppear {
            startDownload()
        }
        // 标题栏红点关闭不走 cancelDownload——监听窗口关闭，下载中则取消，
        // 避免"窗口已关下载仍在后台跑"；取消/完成/安装路径 closeWindow 时状态
        // 已非 downloading，不会误触发
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let closingWindow = note.object as? NSWindow, closingWindow === windowRef,
                  downloadStatus == .downloading else { return }
            DownloadManager.shared.cancel(urlKey: downloadURL.absoluteString)
        }
    }

    private func startDownload() {
        // 同 URL 已有完成的下载且文件仍在（窗口复用/重试场景）——直接展示完成态，
        // 不作废已有结果重新下载
        if let existing = DownloadManager.shared.completedFile(for: downloadURL.absoluteString) {
            downloadedFileURL = existing
            downloadStatus = .completed
            return
        }
        downloadStatus = .downloading
        downloadProgress = 0
        errorMessage = ""

        DownloadManager.shared.download(
            from: downloadURL,
            urlKey: downloadURL.absoluteString,
            // struct 按值捕获，无需 [weak self]
            // 回调已通过 Task @MainActor 派发回主线程
            onProgress: { progress in
                self.downloadProgress = progress
            },
            onComplete: { localURL in
                self.downloadedFileURL = localURL
                self.downloadStatus = .completed
            },
            onError: { error in
                self.downloadStatus = .failed
                self.errorMessage = error
            }
        )
    }

    private func cancelDownload() {
        // 先标 failed：cancel() 后 onError 仍可能被派发，防止异步回调再改 UI 状态
        downloadStatus = .failed
        DownloadManager.shared.cancel(urlKey: downloadURL.absoluteString)
        closeWindow()
    }

    private func copyDownloadLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(downloadURL.absoluteString, forType: .string)
    }

    /// 安装新版本并重启应用
    private func installAndRelaunch() {
        guard let fileURL = downloadedFileURL else { return }
        RelaunchManager.shared.installAndRelaunch(from: fileURL)
    }

    /// 直接打开下载的文件（降级方案，让用户手动安装）
    private func openDownloadedFile() {
        guard let fileURL = downloadedFileURL else { return }
        NSWorkspace.shared.open(fileURL)
        closeWindow()
    }

    private func closeWindow() {
        // 关闭自己持有的窗口，绝不 fallback 到 keyWindow
        if let window = windowRef {
            window.close()
        } else {
            dismissWindow()
        }
    }
}

// MARK: - 抓取宿主 NSWindow
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

// MARK: - 下载管理器
// 按 URL 串行化：同 URL 多次下载会取消旧 task
// @MainActor 保证状态读写串行化；delegate 方法标 nonisolated + MainActor.run 派发，
// 解决 Swift 6 strict concurrency 下与 URLSession 后台回调的冲突
@MainActor
class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    private let log = OSLog(subsystem: "com.swallowscreen.SwallowScreen", category: "DownloadManager")
    private var session: URLSession?
    private var activeTasks: [String: URLSessionDownloadTask] = [:] // urlKey -> task
    private var callbacks: [String: TaskCallbacks] = [:]
    // urlKey → 最近一次成功下载的本地文件（窗口复用时直接展示完成态，不作废重下）
    // 生命周期与应用进程一致：条目仅数十字节，无上限增长风险；文件本身在系统临时目录
    // 由系统清理，completedFile(for:) 读取时有 fileExists 兜底，文件被清理后自动视为未下载
    private var completedFiles: [String: URL] = [:]

    struct TaskCallbacks {
        var onProgress: (Double) -> Void
        var onComplete: (URL?) -> Void
        var onError: (String) -> Void
    }

    /// 下载失败统一出口：上报错误并清理该 URL 的回调与 task 记录
    /// （调用方均在 delegate 的 MainActor Task 内；didCompleteWithError 的身份校验不在本方法——
    ///  它必须先于任何清理执行，语义不同）
    private func reportErrorAndCleanup(urlKey: String, message: String) {
        callbacks[urlKey]?.onError(message)
        callbacks[urlKey] = nil
        activeTasks[urlKey] = nil
    }

    func download(from url: URL,
                  urlKey: String,
                  onProgress: @escaping (Double) -> Void,
                  onComplete: @escaping (URL?) -> Void,
                  onError: @escaping (String) -> Void) {
        // 同 URL 已经有下载在进行，先取消旧 task 避免互相覆盖回调
        if let existing = activeTasks[urlKey] {
            existing.cancel()
            activeTasks[urlKey] = nil
            callbacks[urlKey] = nil
        }

        if session == nil {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 1
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 1800
            session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        }

        callbacks[urlKey] = TaskCallbacks(onProgress: onProgress, onComplete: onComplete, onError: onError)

        var request = URLRequest(url: url)
        request.setValue("SwallowScreen/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let task = session?.downloadTask(with: request)
        // 用 urlKey 作为 taskDescription 便于在 delegate 中回查
        task?.taskDescription = urlKey
        activeTasks[urlKey] = task
        task?.resume()
    }

    /// 查询同 URL 最近一次成功下载且文件仍在的结果（文件可能已被系统/用户清理）
    func completedFile(for urlKey: String) -> URL? {
        guard let fileURL = completedFiles[urlKey],
              FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    func cancel(urlKey: String) {
        if let task = activeTasks[urlKey] {
            task.cancel()
        }
        activeTasks[urlKey] = nil
        callbacks[urlKey] = nil
    }

    // MARK: - URLSessionDownloadDelegate
    // 全部标 nonisolated，内部用 MainActor.run 派发回主线程，
    // 解决 @MainActor conformance 与 URLSession 后台回调的冲突

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let urlKey = downloadTask.taskDescription else { return }

        // 服务器/代理返回错误时 URLSession 也走"成功"路径，body 是 HTML 错误页——
        // 状态码与内容类型必须校验，否则错误页会被存成 .dmg 并提示"下载完成"
        if let http = downloadTask.response as? HTTPURLResponse {
            if !(200..<300).contains(http.statusCode) {
                Task { @MainActor [weak self] in
                    self?.reportErrorAndCleanup(urlKey: urlKey, message: "服务器返回 \(http.statusCode)，下载中止")
                }
                return
            }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if mime.contains("text/html") {
                Task { @MainActor [weak self] in
                    self?.reportErrorAndCleanup(urlKey: urlKey, message: "下载内容异常（HTML 页面），请检查网络或代理设置")
                }
                return
            }
        }

        let fileManager = FileManager.default
        // 使用临时目录而非 Documents——下载的安装包是一次性的，不需要持久保存
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("SwallowScreenUpdates", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            Task { @MainActor [weak self] in
                self?.reportErrorAndCleanup(urlKey: urlKey, message: "无法创建临时目录：\(error.localizedDescription)")
            }
            return
        }

        // suggestedFilename 来自服务器响应头（第三方渠道下完全可控），URLSession 不消毒
        // ".." 与 "/"——必须 basename 清洗，防路径穿越把文件写到下载目录之外
        let rawName = downloadTask.response?.suggestedFilename ?? location.lastPathComponent
        var fileName = rawName.lastPathComponent
        if fileName.isEmpty || fileName == "." {
            fileName = "SwallowScreen-update"
        }
        let destinationURL = tempDir.appendingPathComponent(fileName)

        do {
            // 临时文件在 delegate 返回后即被系统删除，必须在返回前同步转移
            // （同卷 rename 原子近似零耗时，不会阻塞主线程；此前后台 copyItem
            //  必然晚于 delegate 返回执行，源文件已被系统回收导致"保存文件失败"）
            try UpdateDownloadPersistence.persistDownloadedFile(at: location, to: destinationURL)
        } catch {
            os_log("保存下载文件失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
            Task { @MainActor [weak self] in
                self?.reportErrorAndCleanup(urlKey: urlKey, message: "保存文件失败: \(error.localizedDescription)")
            }
            return
        }

        Task.detached(priority: .utility) {
            // 清理之前的旧更新下载文件（保留当前文件）；
            // relaunch.log 必须排除——RelaunchManager 把安装失败取证日志放在本目录，
            // 误删会让 bug-58 类问题的唯一取证手段失效
            if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for file in contents where file != destinationURL && file.lastPathComponent != "relaunch.log" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            // 集中在同一个 MainActor.run：onComplete 与 callbacks/activeTasks 清理一起完成，
            // 避免与 didCompleteWithError 的清理互相冲突
            await MainActor.run { [weak self] in
                // 与 didCompleteWithError 同款身份校验：用户点取消后此完成回调才到达时
                // （cancel 已清 activeTasks），已取消任务的结果不得写入 completedFiles
                // 产生"幽灵完成"复用、也不得误报 UI
                guard self?.activeTasks[urlKey] === downloadTask else { return }
                self?.completedFiles[urlKey] = destinationURL
                self?.callbacks[urlKey]?.onComplete(destinationURL)
                self?.callbacks[urlKey] = nil
                self?.activeTasks[urlKey] = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let urlKey = downloadTask.taskDescription else { return }
        // 响应无 Content-Length（chunked 传输）时无从计算百分比——以 -1 标记不确定态
        let progress: Double = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : -1
        Task { @MainActor [weak self] in
            self?.callbacks[urlKey]?.onProgress(progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlKey = task.taskDescription else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 同 URL 重下后 activeTasks 已指向新 task——旧 task 的收尾回调不得
            // 误删新 task 的记录（否则后续无法真正取消新下载）、不得误报给新 UI
            guard self.activeTasks[urlKey] === task else { return }
            self.activeTasks[urlKey] = nil
            guard let error = error else { return }
            if (error as NSError).code == NSURLErrorCancelled {
                // 用户主动取消（cancel(urlKey:) 已清 callbacks，此处幂等兜底）
                self.callbacks[urlKey] = nil
                return
            }
            // 成功路径已清理 callbacks[urlKey]；若为 nil 说明 onComplete 已回调，
            // 此处不应再 onError，否则同一 urlKey 两个回调都触发，UI 状态错乱
            guard self.callbacks[urlKey] != nil else { return }
            os_log("下载失败: %{public}@", log: self.log, type: .error, error.localizedDescription)
            self.callbacks[urlKey]?.onError(error.localizedDescription)
            self.callbacks[urlKey] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            os_log("URLSession 无效: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
        }
    }
}

#Preview {
    DownloadWindowContentView(version: "1.0.0", downloadURL: URL(string: "https://github.com/Qithking/SwallowScreen/releases/download/v1.0.0/SwallowScreen.dmg")!)
}
