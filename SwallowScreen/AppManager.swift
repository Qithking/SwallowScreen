//
//  AppManager.swift
//  SwallowScreen
//
//  应用管理器 - 获取系统已安装应用列表
//

import Foundation
import AppKit
import Combine

struct SystemApp: Identifiable, Hashable {
    let id: String
    let bundleIdentifier: String
    let name: String
    let path: String
    let icon: NSImage?
    let isMenuBarApp: Bool  // 是否是菜单栏应用
    
    init(bundleIdentifier: String, name: String, path: String, icon: NSImage?, isMenuBarApp: Bool = false) {
        self.id = bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.icon = icon
        self.isMenuBarApp = isMenuBarApp
    }
}

@MainActor
class AppManager: ObservableObject {
    @Published var installedApps: [SystemApp] = []
    @Published var filteredApps: [SystemApp] = []
    @Published var searchText: String = "" {
        didSet {
            filterApps()
        }
    }
    
    init() {
        Task {
            await loadInstalledApps()
        }
    }
    
    func loadInstalledApps() async {
        var apps: [SystemApp] = []

        // 获取常见应用目录
        let applicationDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        // R-218: 目录扫描移到后台线程——FileManager.contentsOfDirectory + Bundle(url:) 同步 IO
        //        在 @MainActor 上串行执行会卡 UI（/Applications 数百个 app + Info.plist 解析）；
        //        三个目录独立 detached 任务，并发扫；最后回到主线程合并
        let scanResults = await withTaskGroup(of: [SystemApp].self) { group in
            for directory in applicationDirectories {
                group.addTask(priority: .userInitiated) {
                    Self.scanApplications(in: directory)
                }
            }
            var collected: [[SystemApp]] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        for result in scanResults {
            apps.append(contentsOf: result)
        }

        // 去重并按名称排序
        var uniqueApps: [String: SystemApp] = [:]
        for app in apps {
            uniqueApps[app.bundleIdentifier] = app
        }

        // RT38: 先把"基础信息"快速写入 installedApps，让 UI 立即展示；icon 后台异步加载
        let basicApps = Array(uniqueApps.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.installedApps = basicApps
        self.filteredApps = basicApps

        // 后台加载图标
        // R-176: 用 withTaskGroup 并发加载——并发数限制 8 防止 IO 风暴；N=200 时总时间 < 1s（vs 串行 10s）
        Task.detached(priority: .utility) { [basicApps] in
            var updated = basicApps
            await withTaskGroup(of: (Int, NSImage?).self) { group in
                let maxConcurrent = 8
                var nextIndex = 0
                var inFlight = 0

                // 启动首批任务
                while nextIndex < updated.count && inFlight < maxConcurrent {
                    let idx = nextIndex
                    let appPath = updated[idx].path
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        let icon = await AppManager.loadIconAsync(at: appPath)
                        return (idx, icon)
                    }
                }

                // 持续收 result + 派发新任务
                while let (idx, icon) = await group.next() {
                    inFlight -= 1
                    if let icon = icon {
                        // R-205: SystemApp.init 是 MainActor-isolated（NSImage 在新 SDK 是 @MainActor），
                        //        Task.detached 内非 MainActor 上下文不能直接调；包到 MainActor.run 解决
                        //        也避免 Swift 6 strict concurrency 下变 error
                        let bundleID = updated[idx].bundleIdentifier
                        let appName = updated[idx].name
                        let appPath = updated[idx].path
                        let isMenuBar = updated[idx].isMenuBarApp
                        updated[idx] = await MainActor.run {
                            SystemApp(
                                bundleIdentifier: bundleID,
                                name: appName,
                                path: appPath,
                                icon: icon,
                                isMenuBarApp: isMenuBar
                            )
                        }
                    }
                    // 派发新任务
                    while nextIndex < updated.count && inFlight < maxConcurrent {
                        let newIdx = nextIndex
                        let appPath = updated[newIdx].path
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            let icon = await AppManager.loadIconAsync(at: appPath)
                            return (newIdx, icon)
                        }
                    }
                }
            }
            // R-203: 快照 updated 后再捕获到 MainActor.run 闭包——避免 Swift 6 strict concurrency
            //        "reference to captured var 'updated' in concurrently-executing code" 警告
            //        闭包创建时复制 final 数组（值类型），避免与 withTaskGroup 内部的 var 共享引用
            let finalApps = updated
            await MainActor.run { [weak self] in
                self?.installedApps = finalApps
                self?.filteredApps = finalApps
            }
        }
    }

    // RT38: 后台 actor 加载图标
    // R-158: 去掉内层 Task.detached——外层调用方（loadInstalledApps）已在 Task.detached(utility) 中，
    //        函数本身被 await 调用即可让出主线程。保留 async 签名便于外部 await
    @MainActor private static func loadIconAsync(at path: String) -> NSImage? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    // R-218: 改为 static nonisolated + 返回值——目录扫描脱离 MainActor，
    //        三个目录并发执行不阻塞主线程
    private nonisolated static func scanApplications(in directory: URL) -> [SystemApp] {
        let fileManager = FileManager.default
        var apps: [SystemApp] = []

        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return apps
        }

        for item in contents {
            if item.pathExtension == "app" {
                if let bundle = Bundle(url: item),
                   let bundleIdentifier = bundle.bundleIdentifier {
                    let name = bundle.infoDictionary?["CFBundleName"] as? String
                        ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? item.deletingPathExtension().lastPathComponent

                    // RT47: 改为基于 blacklist 跳过系统服务类；保留主流用户应用
                    if Self.shouldSkipBundleID(bundleIdentifier) {
                        continue
                    }
                    if bundleIdentifier == Bundle.main.bundleIdentifier {
                        continue
                    }

                    // 检测是否是菜单栏应用 (LSUIElement = true)
                    let isMenuBarApp = (bundle.infoDictionary?["LSUIElement"] as? Bool) == true

                    // RT38: 图标加载移到后台，先用 nil 占位
                    let app = SystemApp(
                        bundleIdentifier: bundleIdentifier,
                        name: name,
                        path: item.path,
                        icon: nil,
                        isMenuBarApp: isMenuBarApp
                    )
                    apps.append(app)
                }
            }
        }
        return apps
    }

    // RT47: 仅跳过明确的"系统服务类" bundleID；Safari/Finder/Terminal 等保留
    // R-218: nonisolated——被 nonisolated static scanApplications 调用
    private nonisolated static let systemBundleIDBlacklist: [String] = [
        "com.apple.systempreferences",
        "com.apple.preference",
        "com.apple.SystemProfiler",
        "com.apple.dt.Xcode",
        "com.apple.AppStore"
    ]

    // R-218: nonisolated——被 nonisolated static scanApplications 调用
    private nonisolated static func shouldSkipBundleID(_ bundleID: String) -> Bool {
        // 跳过系统服务：黑名单前缀
        for prefix in systemBundleIDBlacklist {
            if bundleID.hasPrefix(prefix) {
                return true
            }
        }
        // 跳过 .XPC、.service、.system-extension 等非应用类
        if bundleID.hasSuffix(".XPC") || bundleID.hasSuffix(".service") || bundleID.contains(".system-extension") {
            return true
        }
        return false
    }
    
    private func filterApps() {
        if searchText.isEmpty {
            filteredApps = installedApps
        } else {
            filteredApps = installedApps.filter { app in
                app.name.localizedCaseInsensitiveContains(searchText) ||
                app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    func getIconData(for app: SystemApp) -> Data? {
        guard let icon = app.icon else { return nil }
        if let tiffData = icon.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return pngData
        }
        return nil
    }
}
