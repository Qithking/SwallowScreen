//
//  AppManager.swift
//  SwallowScreen
//
//  应用管理器 - 获取系统已安装应用列表
//

import Foundation
import AppKit
import Combine
import ImageIO

struct SystemApp: Identifiable, Hashable, Sendable {
    let id: String
    let bundleIdentifier: String
    let name: String
    let path: String
    let icon: NSImage?  // NSImage 在 Swift 6 是 @MainActor，但 struct 标记 Sendable 后
                        // nonisolated 上下文可构造（icon 传 nil 时无 NSImage 跨隔离问题）
    let isMenuBarApp: Bool

    // nonisolated init：允许在 Task.detached / static nonisolated 方法中构造
    nonisolated init(bundleIdentifier: String, name: String, path: String, icon: NSImage?, isMenuBarApp: Bool = false) {
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

        let applicationDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        // 目录扫描为同步 IO（数百个 app + Info.plist 解析），主线程串行执行会卡 UI，
        // 故按目录拆成后台并发任务，完成后再回主线程合并
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

        var uniqueApps: [String: SystemApp] = [:]
        for app in apps {
            uniqueApps[app.bundleIdentifier] = app
        }

        // icon 按需加载（AppRowView.onAppear 触发），避免一次性加载全部图标常驻内存
        // localizedStandardCompare：系统标准排序规则，且避免重复构造 Locale
        let basicApps = Array(uniqueApps.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.installedApps = basicApps
        self.filteredApps = basicApps
    }

    // MARK: - 图标懒加载

    /// 缓存已加载的图标，key 为 App 路径。命中复用，避免重复 IO + 解码
    /// 限制条目数（约屏幕可见行数 + 滚动缓冲），超出按 LRU 淘汰，防止滚动后图标全量常驻内存
    private var iconCache: [String: NSImage] = [:]
    private var iconCacheOrder: [String] = []  // LRU 插入顺序，最旧在首
    private let iconCacheMaxSize = 60
    /// 正在加载的路径集合，防止同一图标并发请求
    private var iconLoadingSet: Set<String> = []
    /// 等待队列：同一 path 的多个请求在加载完成时依次回调
    /// （快速滚动时新行 onAppear 会在图标加载中再次请求，若直接 return 新行将收不到回调）
    private var iconPendingCompletions: [String: [@MainActor (NSImage?) -> Void]] = [:]

    /// 异步请求 App 图标。
    /// - 命中缓存：同步回调返回（同时更新 LRU 顺序）
    /// - 未命中 + 首次请求：后台线程加载 + 缓存（带 LRU 淘汰） + 回调
    /// - 未命中 + 正在加载中：将 completion 追加到等待队列，加载完成后统一回调
    func requestIcon(for app: SystemApp, completion: @escaping @MainActor (NSImage?) -> Void) {
        let path = app.path
        if let cached = iconCache[path] {
            promoteIconCacheKey(path)
            completion(cached)
            return
        }
        if iconLoadingSet.contains(path) {
            iconPendingCompletions[path, default: []].append(completion)
            return
        }
        iconLoadingSet.insert(path)
        iconPendingCompletions[path, default: []].append(completion)

        Task.detached(priority: .utility) {
            // Swift 6: Task.detached 闭包不能捕获 @MainActor 的 self
            // 先在闭包外捕获需要的值，闭包内只使用这些值
            let icon = Self.loadIconSync(at: path)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.iconLoadingSet.remove(path)
                if let icon = icon {
                    self.insertIconCache(path: path, icon: icon)
                }
                let completions = self.iconPendingCompletions.removeValue(forKey: path) ?? []
                for callback in completions {
                    callback(icon)
                }
            }
        }
    }

    /// 插入图标到缓存，超出上限时淘汰最旧的
    private func insertIconCache(path: String, icon: NSImage) {
        // 已存在则仅更新顺序（理论上不会发生——命中缓存会提前 return）
        if iconCache[path] != nil {
            promoteIconCacheKey(path)
            return
        }
        iconCache[path] = icon
        iconCacheOrder.append(path)
        // 超出上限：淘汰最旧一半（30 条）
        if iconCacheOrder.count > iconCacheMaxSize {
            let removeCount = iconCacheOrder.count - iconCacheMaxSize + (iconCacheMaxSize / 2)
            let toRemove = iconCacheOrder.prefix(removeCount)
            for key in toRemove {
                iconCache.removeValue(forKey: key)
            }
            iconCacheOrder.removeFirst(removeCount)
        }
    }

    /// 命中缓存时把 key 移到末尾（标记最近使用）
    private func promoteIconCacheKey(_ key: String) {
        if let index = iconCacheOrder.firstIndex(of: key) {
            iconCacheOrder.remove(at: index)
            iconCacheOrder.append(key)
        }
    }

    /// 同步加载图标。ImageIO 无法解码 .app bundle 目录，故直接走 NSWorkspace API
    nonisolated private static func loadIconSync(at path: String) -> NSImage? {
        return NSWorkspace.shared.icon(forFile: path)
    }

    // static nonisolated：目录扫描脱离 MainActor，供后台任务并发执行不阻塞主线程
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

                    if Self.shouldSkipBundleID(bundleIdentifier) {
                        continue
                    }
                    if bundleIdentifier == Bundle.main.bundleIdentifier {
                        continue
                    }

                    let isMenuBarApp = (bundle.infoDictionary?["LSUIElement"] as? Bool) == true

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

    // 仅跳过明确的"系统服务类" bundleID；Safari/Finder/Terminal 等保留
    // nonisolated：被 nonisolated static scanApplications 调用
    private nonisolated static let systemBundleIDBlacklist: [String] = [
        "com.apple.systempreferences",
        "com.apple.preference",
        "com.apple.SystemProfiler",
        "com.apple.dt.Xcode",
        "com.apple.AppStore"
    ]

    // nonisolated：被 nonisolated static scanApplications 调用
    private nonisolated static func shouldSkipBundleID(_ bundleID: String) -> Bool {
        for prefix in systemBundleIDBlacklist {
            if bundleID.hasPrefix(prefix) {
                return true
            }
        }
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
}
