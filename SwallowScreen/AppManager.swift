//
//  AppManager.swift
//  SwallowScreen
//
//  应用管理器 - 获取系统已安装应用列表
//

import Foundation
import AppKit
import Combine
import ImageIO  // R-M3-rev: CGImageSource 解码 → 单 CGImage

struct SystemApp: Identifiable, Hashable, Sendable {
    let id: String
    let bundleIdentifier: String
    let name: String
    let path: String
    let icon: NSImage?  // NSImage 在 Swift 6 是 @MainActor，但 struct 标记 Sendable 后
                        // nonisolated 上下文可构造（icon 传 nil 时无 NSImage 跨隔离问题）
    let isMenuBarApp: Bool  // 是否是菜单栏应用

    // nonisolated init：允许在 Task.detached / static nonisolated 方法中构造
    // 传 icon: nil 时无 @MainActor 跨隔离问题
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

        // M2: 不再预填所有 icon——icon 改为按需懒加载（AppRowView.onAppear 触发）
        //     旧逻辑：200+ NSImage 一次性加载 → 30-100MB 内存常驻
        //     新逻辑：仅当前可见行（LazyVStack 10-20 个）会触发 loadIconSync
        // M6: 用 localizedStandardCompare 替代 localizedCaseInsensitiveCompare——
        //     系统标准排序规则 + 更优性能（避免重复调用 compare 时构造临时 Locale）
        let basicApps = Array(uniqueApps.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.installedApps = basicApps
        self.filteredApps = basicApps
    }

    // MARK: - 图标懒加载（M2+M3）

    /// 缓存已加载的图标，key 为 App 路径。命中复用，避免重复 IO + CGImage 解码
    /// P2-图标LRU: 加 maxSize 限制——用户滚动后 200+ 图标全常驻内存（即使单图 20-30KB，总量 4-6MB）；
    ///     实际 NSImage wrapper + 缓存数组对象额外开销更可观。
    ///     限制 60 个条目（约屏幕可见行数 + 滚动缓冲），超出时按 LRU 淘汰
    private var iconCache: [String: NSImage] = [:]
    private var iconCacheOrder: [String] = []  // LRU 插入顺序，最旧在首
    private let iconCacheMaxSize = 60
    /// 正在加载的路径集合，防止同一图标并发请求
    private var iconLoadingSet: Set<String> = []
    /// 等待队列：同一 path 的多个请求在加载完成时依次回调
    /// 修复竞态：快速滚动时 LazyVStack 销旧行创建新行，新行的 onAppear 再次请求同一图标，
    ///           此时 iconLoadingSet 已包含 path，旧逻辑直接 return 导致新行收不到回调
    private var iconPendingCompletions: [String: [@MainActor (NSImage?) -> Void]] = [:]

    /// 异步请求 App 图标。
    /// - 命中缓存：同步回调返回（同时更新 LRU 顺序）
    /// - 未命中 + 首次请求：后台线程加载 + 缓存（带 LRU 淘汰） + 回调
    /// - 未命中 + 正在加载中：将 completion 追加到等待队列，加载完成后统一回调
    func requestIcon(for app: SystemApp, completion: @escaping @MainActor (NSImage?) -> Void) {
        let path = app.path
        if let cached = iconCache[path] {
            // P2-图标LRU: 命中缓存，更新 LRU 顺序
            promoteIconCacheKey(path)
            completion(cached)
            return
        }
        if iconLoadingSet.contains(path) {
            // 修复竞态：同一图标正在加载中，将 completion 追加到等待队列
            iconPendingCompletions[path, default: []].append(completion)
            return
        }
        iconLoadingSet.insert(path)
        // 首次请求也加入等待队列
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
                // 回调所有等待者（包括首次请求和竞态追加的）
                let completions = self.iconPendingCompletions.removeValue(forKey: path) ?? []
                for callback in completions {
                    callback(icon)
                }
            }
        }
    }

    /// P2-图标LRU: 插入图标到缓存，超出上限时淘汰最旧的
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

    /// P2-图标LRU: 命中缓存时把 key 移到末尾（标记最近使用）
    private func promoteIconCacheKey(_ key: String) {
        if let index = iconCacheOrder.firstIndex(of: key) {
            iconCacheOrder.remove(at: index)
            iconCacheOrder.append(key)
        }
    }

    /// 同步加载图标（M3: 限制为单一目标尺寸的 NSImage，内存占用最优）
    /// 旧实现 `NSWorkspace.shared.icon(forFile:)` 返回的 NSImage 包含 16/32/128/256/512/1024 等多尺寸 representation，
    /// 单图实际内存 50-200KB。新实现只保留 24×24 单一表示，单图 ~10-20KB。
    /// 实现思路：用 CGImageSource 取最大尺寸 → CGImage → 缩放到 24x24 → 包成 NSImage
    nonisolated private static func loadIconSync(at path: String) -> NSImage? {
        let targetSize = NSSize(width: 24, height: 24)
        // R-M3-rev: macOS 26 SDK 下 `bestRepresentation(for:context:hints:)` 签名变更，
        // 改用 CGImageSource 直接解码 → 单一 CGImage → NSImage，绕开 NSImage 内部 representations 缓存
        let url = URL(fileURLWithPath: path) as CFURL
        if let source = CGImageSourceCreateWithURL(url, nil),
           let fullImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            // 缩放到 24x24——单 CGImage，NSImage 只持一份 representation
            let width = Int(targetSize.width)
            let height = Int(targetSize.height)
            if let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                context.interpolationQuality = .high
                context.draw(fullImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let scaledCGImage = context.makeImage() {
                    return NSImage(cgImage: scaledCGImage, size: targetSize)
                }
            }
            return NSImage(cgImage: fullImage, size: targetSize)
        }
        // 兜底：NSWorkspace API 在 macOS 各版本稳定，但可能保留多 representations
        return NSWorkspace.shared.icon(forFile: path)
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
}
