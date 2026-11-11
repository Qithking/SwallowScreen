//
//  DownloadWindow.swift
//  SwallowScreen
//
//  下载窗口视图 - 显示下载进度
//

import SwiftUI
import AppKit
import os.log

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
                    Text("正在下载 v\(version)")
                        .font(.headline)

                    if downloadStatus == .downloading {
                        VStack(alignment: .leading, spacing: 3) {
                            ProgressView(value: downloadProgress)
                                .progressViewStyle(.linear)
                                .frame(height: 8)

                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
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
    }

    private func startDownload() {
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

    struct TaskCallbacks {
        var onProgress: (Double) -> Void
        var onComplete: (URL?) -> Void
        var onError: (String) -> Void
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
        let fileManager = FileManager.default
        // 使用临时目录而非 Documents——下载的安装包是一次性的，不需要持久保存
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("SwallowScreenUpdates", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            Task { @MainActor [weak self] in
                self?.callbacks[urlKey]?.onError("无法创建临时目录：\(error.localizedDescription)")
                self?.callbacks[urlKey] = nil
                self?.activeTasks[urlKey] = nil
            }
            return
        }

        let fileName = downloadTask.response?.suggestedFilename ?? location.lastPathComponent
        let destinationURL = tempDir.appendingPathComponent(fileName)

        do {
            // 临时文件在 delegate 返回后即被系统删除，必须在返回前同步转移
            // （同卷 rename 原子近似零耗时，不会阻塞主线程；此前后台 copyItem
            //  必然晚于 delegate 返回执行，源文件已被系统回收导致"保存文件失败"）
            try UpdateDownloadPersistence.persistDownloadedFile(at: location, to: destinationURL)
        } catch {
            os_log("保存下载文件失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
            Task { @MainActor [weak self] in
                self?.callbacks[urlKey]?.onError("保存文件失败: \(error.localizedDescription)")
                self?.callbacks[urlKey] = nil
                self?.activeTasks[urlKey] = nil
            }
            return
        }

        Task.detached(priority: .utility) {
            // 清理之前的旧更新下载文件（保留当前文件）
            if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for file in contents where file != destinationURL {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            // 集中在同一个 MainActor.run：onComplete 与 callbacks/activeTasks 清理一起完成，
            // 避免与 didCompleteWithError 的清理互相冲突
            await MainActor.run { [weak self] in
                self?.callbacks[urlKey]?.onComplete(destinationURL)
                self?.callbacks[urlKey] = nil
                self?.activeTasks[urlKey] = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let urlKey = downloadTask.taskDescription else { return }
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            Task { @MainActor [weak self] in
                self?.callbacks[urlKey]?.onProgress(progress)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlKey = task.taskDescription else { return }
        Task { @MainActor [weak self] in
            self?.activeTasks[urlKey] = nil
            if let error = error {
                if (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                // 成功路径已清理 callbacks[urlKey]；若为 nil 说明 onComplete 已回调，
                // 此处不应再 onError，否则同一 urlKey 两个回调都触发，UI 状态错乱
                guard self?.callbacks[urlKey] != nil else { return }
                os_log("下载失败: %{public}@", log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                self?.callbacks[urlKey]?.onError(error.localizedDescription)
                self?.callbacks[urlKey] = nil
            }
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
