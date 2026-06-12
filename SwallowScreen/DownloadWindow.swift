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
/// RT10: 单例 + 复用窗口；多次下载只会有一个窗口，重复触发时聚焦已有窗口
/// RT63: 显式 @MainActor，与 macOS 14+ NSWindowController 隔离保证一致
@MainActor
class DownloadWindowController: NSWindowController {
    static let shared = DownloadWindowController()

    // 用于单例 init：先创建 nil 窗口，show(...) 时按需创建
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
    /// - Returns: (hostingController, contentView) 元组，调用方负责把 view 数据塞进 contentView
    func showWindow() {
        // RT10: 窗口已可见则聚焦，不再创建
        if let w = window, !w.isVisible {
            w.center()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// RT70: 封装"创建 contentViewController + 替换 + showWindow"流程
    /// 调用方只需一行：DownloadWindowController.open(version:, downloadURL:)
    static func open(version: String, downloadURL: URL) {
        let controller = DownloadWindowController.shared
        // RT30: window 防御
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

    // T23: 持有对自己窗口的弱引用，避免 closeWindow 误关其他窗口
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var windowRef: NSWindow?

    enum DownloadStatus {
        case downloading
        case completed
        case failed
    }

    var body: some View {
        VStack(spacing: 10) {
            // 上半部分：左边图标 + 右边进度条
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
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 380, height: 140)
        .background(
            // 通过 Introspect 抓取宿主 NSWindow，存到 @State；关闭时直接 close 自己
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
            // R-204: DownloadWindowContentView 是 struct（SwiftUI View）——值类型，
            //        [weak self] 不适用（weak 只能用于 class/class-bound protocol），
            //        也无 retain cycle 风险（struct 按值捕获）
            //        原代码触发 3x `weak may only be applied to class types` + 3x `self never mutated`
            onProgress: { progress in
                // RT45: 显式主线程派发（防御 URLSession 路径变更）
                DispatchQueue.main.async {
                    self.downloadProgress = progress
                }
            },
            onComplete: { localURL in
                // RT49: Task @MainActor 替代 asyncAfter
                Task { @MainActor in
                    if let url = localURL {
                        NSWorkspace.shared.open(url)
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.closeWindow()
                }
            },
            onError: { error in
                DispatchQueue.main.async {
                    self.downloadStatus = .failed
                    self.errorMessage = error
                }
            }
        )
    }

    private func cancelDownload() {
        DownloadManager.shared.cancel(urlKey: downloadURL.absoluteString)
        closeWindow()
    }

    private func copyDownloadLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(downloadURL.absoluteString, forType: .string)
    }

    private func closeWindow() {
        // T23: 关闭自己持有的窗口，绝不 fallback 到 keyWindow
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
// T15: 改为按 URL 串行化；同 URL 多次下载会取消旧 task
// R-212: 删除 @MainActor——URLSessionDelegate 方法在后台线程调用，
//        与 @MainActor 隔离冲突（Swift 6 error: conformance crosses into main actor-isolated code）
class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    private let log = OSLog(subsystem: "com.swallowscreen.SwallowScreen", category: "DownloadManager")
    private var session: URLSession?
    // R-212: @MainActor 已删除，但 activeTasks/callbacks 只在主线程访问，
    //        用 NSLock 保护以兼容 Swift 6 strict concurrency
    private let lock = NSLock()
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
        lock.lock()
        defer { lock.unlock() }
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
        // T19: 用 urlKey 作为 taskDescription 便于在 delegate 中回查
        task?.taskDescription = urlKey
        activeTasks[urlKey] = task
        task?.resume()
    }

    func cancel(urlKey: String) {
        lock.lock()
        defer { lock.unlock() }
        if let task = activeTasks[urlKey] {
            task.cancel()
        }
        activeTasks[urlKey] = nil
        callbacks[urlKey] = nil
    }

    // MARK: - URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // T19: 避免 force unwrap
        guard let urlKey = downloadTask.taskDescription else { return }
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // RT45: 主线程派发
            DispatchQueue.main.async { [weak self] in
                self?.lock.lock()
                self?.callbacks[urlKey]?.onError("找不到 Documents 目录")
                self?.lock.unlock()
            }
            return
        }

        let fileName = downloadTask.response?.suggestedFilename ?? location.lastPathComponent
        let destinationURL = documentsURL.appendingPathComponent(fileName)

        try? fileManager.removeItem(at: destinationURL)

        // R-199: 移到后台线程执行 fileManager.copyItem——>100MB 文件不再阻塞主线程
        //        URLSession delegateQueue: .main 时主线程会同步等 copyItem 完成
        let locationCopy = location
        let urlKeyCapture = urlKey
        Task.detached(priority: .utility) { [weak self] in
            do {
                try FileManager.default.copyItem(at: locationCopy, to: destinationURL)
                await MainActor.run { [weak self] in
                    self?.lock.lock()
                    self?.callbacks[urlKeyCapture]?.onComplete(destinationURL)
                    self?.callbacks[urlKeyCapture] = nil
                    self?.lock.unlock()
                }
            } catch {
                os_log("保存下载文件失败: %{public}@", log: self?.log ?? OSLog.default, type: .error, error.localizedDescription)
                await MainActor.run { [weak self] in
                    self?.lock.lock()
                    self?.callbacks[urlKeyCapture]?.onError("保存文件失败: \(error.localizedDescription)")
                    self?.callbacks[urlKeyCapture] = nil
                    self?.lock.unlock()
                }
            }
        }

        // R-199: activeTasks 清理在主线程上立即执行（callbacks 清理在 Task.detached 内的成功/失败路径上）
        lock.lock()
        activeTasks[urlKey] = nil
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let urlKey = downloadTask.taskDescription else { return }
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async { [weak self] in
                self?.lock.lock()
                self?.callbacks[urlKey]?.onProgress(progress)
                self?.lock.unlock()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let urlKey = task.taskDescription else { return }
        lock.lock()
        defer { lock.unlock() }
        defer { activeTasks[urlKey] = nil }
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            os_log("下载失败: %{public}@", log: log, type: .error, error.localizedDescription)
            DispatchQueue.main.async { [weak self] in
                self?.lock.lock()
                self?.callbacks[urlKey]?.onError(error.localizedDescription)
                self?.callbacks[urlKey] = nil
                self?.lock.unlock()
            }
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            os_log("URLSession 无效: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }
}

#Preview {
    DownloadWindowContentView(version: "1.0.0", downloadURL: URL(string: "https://github.com/Qithking/SwallowScreen/releases/download/v1.0.0/SwallowScreen.dmg")!)
}
