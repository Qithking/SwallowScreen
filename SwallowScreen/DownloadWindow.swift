//
//  DownloadWindow.swift
//  SwallowScreen
//
//  下载窗口视图 - 显示下载进度
//

import SwiftUI
import AppKit

// MARK: - 下载窗口控制器
class DownloadWindowController: NSWindowController {
    convenience init(version: String, downloadURL: URL) {
        let contentView = DownloadWindowContentView(version: version, downloadURL: downloadURL)
        let hostingController = NSHostingController(rootView: contentView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "下载更新"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 170))
        window.center()
        window.isReleasedWhenClosed = false
        
        self.init(window: window)
    }
    
    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 下载窗口内容视图
struct DownloadWindowContentView: View {
    let version: String
    let downloadURL: URL
    
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: DownloadStatus = .downloading
    @State private var errorMessage: String = ""
    
    enum DownloadStatus {
        case downloading
        case completed
        case failed
    }
    
    var body: some View {
        VStack(spacing: 10) {
            // 上半部分：左边图标 + 右边进度条
            HStack(spacing: 12) {
                // 左边：应用图标
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
                
                // 右边：进度信息
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
            
            // 分割线
            Divider()
            
            // 下半部分：左边错误信息 + 右边按钮
            HStack(spacing: 12) {
                // 左边：失败信息
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
                
                // 右边：按钮
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
        .onAppear {
            startDownload()
        }
    }
    
    private var statusIcon: String {
        switch downloadStatus {
        case .downloading:
            return "arrow.down.circle.fill"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var statusColor: Color {
        switch downloadStatus {
        case .downloading:
            return .accentColor
        case .completed:
            return .green
        case .failed:
            return .orange
        }
    }
    
    private var statusText: String {
        switch downloadStatus {
        case .downloading:
            return "正在下载 v\(version)"
        case .completed:
            return "下载完成"
        case .failed:
            return "下载失败"
        }
    }
    
    private func startDownload() {
        downloadStatus = .downloading
        downloadProgress = 0
        errorMessage = ""
        
        DownloadManager.shared.download(from: downloadURL) { progress in
            self.downloadProgress = progress
        } onComplete: { localURL in
            if let url = localURL {
                NSWorkspace.shared.open(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.closeWindow()
            }
        } onError: { error in
            self.downloadStatus = .failed
            self.errorMessage = error
        }
    }
    
    private func cancelDownload() {
        DownloadManager.shared.cancel()
        closeWindow()
    }
    
    private func copyDownloadLink() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(downloadURL.absoluteString, forType: .string)
    }
    
    private func closeWindow() {
        if let window = NSApp.keyWindow {
            window.close()
        }
    }
}

// MARK: - 下载管理器
class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var onProgress: ((Double) -> Void)?
    private var onComplete: ((URL?) -> Void)?
    private var onError: ((String) -> Void)?
    
    func download(from url: URL, onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?) -> Void, onError: @escaping (String) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
        
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 1
        // 请求超时设为 5 分钟，资源下载超时设为 30 分钟
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 1800
        
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        
        var request = URLRequest(url: url)
        request.setValue("SwallowScreen/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        
        downloadTask = session?.downloadTask(with: request)
        downloadTask?.resume()
    }
    
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // 使用响应中的文件名或从URL中提取
        let fileName = self.downloadTask?.response?.suggestedFilename ?? location.lastPathComponent
        let destinationURL = documentsURL.appendingPathComponent(fileName)
        
        try? fileManager.removeItem(at: destinationURL)
        
        do {
            try fileManager.copyItem(at: location, to: destinationURL)
            self.onComplete?(destinationURL)
        } catch {
            self.onError?("保存文件失败: \(error.localizedDescription)")
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            self.onProgress?(progress)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // 用户取消不显示错误
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            self.onError?(error.localizedDescription)
        }
    }
    
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            self.onError?(error.localizedDescription)
        }
    }
}

#Preview {
    DownloadWindowContentView(version: "1.0.0", downloadURL: URL(string: "https://github.com/Qithking/SwallowScreen/releases/download/v1.0.0/SwallowScreen.dmg")!)
}
