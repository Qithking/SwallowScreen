//
//  WindowMover.swift
//  SwallowScreen
//
//  窗口管理器 - 监控和移动应用窗口
//

import Foundation
import AppKit
import CoreGraphics
import SwiftData
import Combine
import os  // P2: Logger（懒插值）— 热路径日志优化（已全量替换 os_log）

@MainActor
class WindowMover: ObservableObject {
    // FIX-响应慢: C 回调需要直接访问实例，不走 NotificationCenter 桥接
    static weak var shared: WindowMover?

    @Published var isMonitoring: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    
    private var timer: DispatchSourceTimer?
    private var modelContext: ModelContext?
    private var checkInterval: TimeInterval = 0.1  // 固定屏幕检查间隔（100ms，平衡响应速度与 CPU）
    private var lastMovedWindows: Set<String> = [] // 冷却中的窗口

    // P2: 统一 Logger 实例——热路径日志懒插值（debug 级别不构造消息字符串）
    private let logger = Logger(subsystem: "com.swallowscreen.SwallowScreen", category: "WindowMover")
    private var previousWindowPositions: [String: CGPoint] = [:] // 上次窗口位置
    // RT57: 维护并列的插入顺序数组，按索引清理最旧的一半
    private var previousWindowPositionsOrder: [String] = []
    // R-151: 配套的 Set，contains 走 O(1)——替代 Array.contains O(n) 性能问题
    private var previousWindowPositionsOrderSet: Set<String> = []
    private var movingWindows: Set<String> = [] // 正在移动的窗口
    // C2: AX 元数据缓存（title/role/size）——按位置 50px 网格分桶
    //     同一窗口静止时复用，AX 系统调用 ↓ ~75%
    //     与 previousWindowPositions 协同：后者管"位置是否变化"，本字典管"title/role/size 是否需要重读"
    private var axMetadataCache: [String: (title: String, role: String, size: CGSize?)] = [:]

    // 观察者 token，用于 deinit 时清理
    private var appLaunchObserverToken: NSObjectProtocol?
    // C3: 屏变化观察者 token——屏变化时使 getCurrentScreenMappings 缓存失效
    private var screenChangeObserverToken: NSObjectProtocol?
    // P1: App 终止观察者 token——App 退出时清理其相关字典键
    private var appTerminationObserverToken: NSObjectProtocol?
    // Space 感知：监听 Space 切换，触发即时 pinToScreen 检查
    // 借鉴 yabai：Space 切换后立即检查新 Space 上的 pinned 窗口位置
    private var spaceChangeObserverToken: NSObjectProtocol?
    // 冷却清理用的 DispatchWorkItem 缓存，便于 deinit 一并取消
    private var cooldownWorkItems: [String: DispatchWorkItem] = [:]
    // T18: AppInfo 列表指纹，用于"配置未变则跳过"
    private var lastAppsFingerprint: Int = 0
    // 缓存 pinned AppInfo 列表——指纹未变时复用，避免每 100ms 都 SwiftData fetch
    private var cachedPinnedApps: [AppInfo] = []
    // RT1: 按 pid 维度持有的检测上下文；新启动同 pid App 会取消旧上下文
    private var activeDetections: [pid_t: DetectionContext] = [:]
    // RT1: 稳态校验每个 pid 独立计数
    private var stabilityCount: [pid_t: Int] = [:]
    // RT14: CG 检测间隔，按屏幕最大帧率动态决定
    // C1: 原 120Hz+ → 8ms、否则 16ms；实际不需要那么高频
    //     30Hz (33ms) 足够"窗口首帧出现"检测；CPU 占用预期 ↓ 50-70%
    //     启动前 ~200ms 仍用 16ms 抢首帧（D2 设计，按 elapsedSinceStart 切换）
    private var cgDetectionInterval: TimeInterval {
        // 简化：固定 33ms（30Hz）。若要保留"前快后慢"，加 elapsedSinceStart 即可
        return 0.033
    }
    // RT65: 启动期 moveAllOpenAppsToAssignedScreens 的 task 句柄，可取消
    private var moveAllAppsTask: Task<Void, Never>?
    // RT74: 启动期 true，期间 checkAndEnforcePinnedWindows 跳过 pinToScreen 防竞态
    private var isPerformingInitialMove: Bool = false

    // AXObserver: 借鉴 yabai 的事件驱动设计，替代双链轮询作为主检测路径
    // 按 pid 持有 AXObserver 实例；窗口创建通知到达后立即搬动，无需轮询
    private var axObservers: [pid_t: AXObserver] = [:]
    private var axRunLoopSources: [pid_t: CFRunLoopSource] = [:]
    // AXObserver 检测上下文：记录每个 pid 的目标 frame 和标题匹配模式，供回调时查找
    private var pendingAXObservations: [pid_t: (targetFrame: CGRect, titlePattern: String?)] = [:]
    // AXObserver 内部通知 token——C 回调通过 NotificationCenter 桥接到 Swift
    private var axWindowCreatedObserverToken: NSObjectProtocol?

    // pinToScreen 专用 AXObserver：监听窗口移动事件（kAXMovedNotification）
    // 窗口被拖到其他屏幕时立即触发检查，无需等 100ms 轮询
    // 与启动检测的 axObservers 独立，pinToScreen observer 长期存活
    private var pinObservers: [pid_t: AXObserver] = [:]
    private var pinRunLoopSources: [pid_t: CFRunLoopSource] = [:]

    // FIX-响应慢: pinObserver 快速路径缓存——pid → (targetFrame, screenID)
    // 窗口移动事件到达时直接查缓存，跳过 SwiftData fetch + runningApplications 遍历
    // 在 refreshPinObservers / invalidateScreenCache 时同步更新
    private var pinTargetCache: [pid_t: (frame: CGRect, visibleFrame: CGRect, screenID: UInt32)] = [:]

    // FIX-响应慢: 缓存 pid → 主窗口 AXUIElement 引用，避免每次 kAXWindowsAttribute 查询（~5-15ms）
    private var pinWindowCache: [pid_t: AXUIElement] = [:]
    // FIX-响应慢: 缓存 pid → 窗口尺寸，避免每次 kAXSizeAttribute 查询（~3-5ms）
    private var pinWindowSizeCache: [pid_t: CGSize] = [:]

    // FIX-拖拽检测: 拖拽中通过 isMouseLeftButtonDown() 检测鼠标状态，
    // 鼠标按下时记录 pid，等全局 leftMouseUp 事件触发后立即回弹
    private var pendingDragCheckPids: Set<pid_t> = []
    private var globalMouseUpMonitor: Any? = nil
    // RT160: scheduleAXFallbackMove 的延迟 workItems，stopMonitoring 时可取消
    private var axFallbackWorkItems: [DispatchWorkItem] = []

    init() {
        _ = checkAccessibilityPermission()
        // FIX-启动不搬窗: NSWorkspace.didLaunchApplicationNotification 监听改到 startMonitoring 中注册，
        //   避免 AppDelegate 延迟 1s 创建 WindowMover 期间丢失应用启动通知
        setupAppTerminationObserver()
        setupScreenChangeObserver()
        setupAXWindowCreatedObserver()
        setupSpaceChangeObserver()
        Self.shared = self
    }

    deinit {
        // FIX: deinit 是 nonisolated，不能直接修改 @MainActor 属性
        // 但 Self.shared 是 weak var，ARC 释放时会自动置 nil，无需手动清理
        // RT149: 显式 cancel 顶层 dispatch timer；之前漏 cancel 导致 ARC 释放时
        //        dispatch source 仍持引用直到 timer 触发或手动 cancel
        self.timer?.cancel()
        if let token = appLaunchObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let token = screenChangeObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = appTerminationObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let token = axWindowCreatedObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = spaceChangeObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        // AXObserver 清理：移除所有 run loop source + observer
        // FIX: deinit 可能在非主线程执行，CFRunLoopGetCurrent() 返回错误的 RunLoop
        //      source 是加在主 RunLoop 上的，必须从主 RunLoop 移除
        let mainRunLoop = CFRunLoopGetMain()
        for (_, source) in axRunLoopSources {
            CFRunLoopRemoveSource(mainRunLoop, source, .defaultMode)
        }
        axRunLoopSources.removeAll()
        axObservers.removeAll()
        pendingAXObservations.removeAll()
        // pinToScreen observer 清理
        for (_, source) in pinRunLoopSources {
            CFRunLoopRemoveSource(mainRunLoop, source, .defaultMode)
        }
        pinRunLoopSources.removeAll()
        pinObservers.removeAll()
        pinTargetCache.removeAll()
        pinWindowCache.removeAll()
        pinWindowSizeCache.removeAll()
        pendingDragCheckPids.removeAll()
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
        for context in activeDetections.values { context.cancel() }
        for item in cooldownWorkItems.values { item.cancel() }
        // RT160: 取消 AX 兜底延迟任务
        for item in axFallbackWorkItems { item.cancel() }
    }

    /// C3: 监听 .screenConfigurationChanged 屏变化事件——失效屏幕缓存
    private func setupScreenChangeObserver() {
        screenChangeObserverToken = NotificationCenter.default.addObserver(
            forName: .screenConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.invalidateScreenCache()
        }
    }

    // MARK: - AXObserver 事件驱动检测（借鉴 yabai）

    /// 监听 AXObserver C 回调通过 NotificationCenter 桥接的窗口创建通知
    /// C 回调无法直接访问 @MainActor 属性，通过 NotificationCenter 转发到主线程
    private func setupAXWindowCreatedObserver() {
        axWindowCreatedObserverToken = NotificationCenter.default.addObserver(
            forName: .axWindowCreatedInternal,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let pid = (notification.userInfo?["pid"] as? NSNumber)?.int32Value else { return }
            let element = notification.userInfo?["element"]
            // AXUIElement 是 CoreFoundation 类型，userInfo 中一定存在（C 回调保证）
            guard let axElement = element else { return }
            Task { @MainActor in
                self.handleAXWindowCreated(pid: pid, element: axElement as! AXUIElement)
            }
        }
    }

    /// Space 感知：监听 Space 切换通知，触发即时 pinToScreen 检查
    /// 借鉴 yabai：Space 切换后，新 Space 上的 pinned 窗口可能位置不对（用户从其他 Space 拖过来），
    /// 需要立即检查并纠正。之前依赖 100ms 定时器轮询，最差延迟 100ms。
    /// NSWorkspaceActiveSpaceDidChangeNotification 在 Space 切换完成时触发。
    private func setupSpaceChangeObserver() {
        spaceChangeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Space 切换后立即检查 pinned 窗口位置
            // 延迟 50ms 让系统完成 Space 切换动画，避免 AX API 在动画期间返回旧位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.checkAndEnforcePinnedWindows()
            }
        }
    }

    /// 为指定 pid 创建 AXObserver，订阅 kAXWindowCreatedNotification
    /// 借鉴 yabai：事件驱动替代轮询，窗口创建即触发搬动，无需 33ms/100ms 双链轮询
    private func setupAXObserver(for pid: pid_t, targetFrame: CGRect, titlePattern: String? = nil) {
        // 记录目标 frame 和标题匹配模式，供回调时查找
        pendingAXObservations[pid] = (targetFrame, titlePattern)

        var observer: AXObserver?
        let result = AXObserverCreate(pid, Self.axObserverCallback, &observer)

        guard result == .success, let observer = observer else {
            logger.debug("AXObserverCreate 失败: pid=\(pid) result=\(result.rawValue)")
            pendingAXObservations.removeValue(forKey: pid)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let addResult = AXObserverAddNotification(
            observer, appElement,
            kAXWindowCreatedNotification as CFString,
            nil
        )
        if addResult != .success {
            logger.debug("AXObserverAddNotification 失败: pid=\(pid) result=\(addResult.rawValue)")
            pendingAXObservations.removeValue(forKey: pid)
            return
        }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        // RT159: 显式使用 CFRunLoopGetMain()，与 removeAXObserver/deinit 中移除保持一致
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        axObservers[pid] = observer
        axRunLoopSources[pid] = runLoopSource
        logger.debug("AXObserver 已创建: pid=\(pid)")
    }

    /// AXObserver C 回调——必须是 static + @convention(c)，无法捕获 Swift 上下文
    /// 通过 NotificationCenter 桥接到 @MainActor 的 handleAXWindowCreated
    private static let axObserverCallback: AXObserverCallback = { observer, element, notification, _ in
        // AXObserverGetPid 不在 Swift 公开 API 中，改用 AXUIElementGetPid 从 element 获取
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else { return }

        let notificationStr = notification as String

        guard notificationStr == kAXWindowCreatedNotification as String else { return }

        // C 回调在主 RunLoop 线程执行（因为 run loop source 加在主线程），
        // 但不在 @MainActor 上下文，通过 NotificationCenter 桥接
        NotificationCenter.default.post(
            name: .axWindowCreatedInternal,
            object: nil,
            userInfo: ["pid": NSNumber(value: pid), "element": element]
        )
    }

    /// AXObserver 检测到新窗口创建——主检测路径（事件驱动，零轮询）
    /// 1. 取消该 pid 的兜底轮询 timer
    /// 2. 对新窗口执行 hide → move → unhide（支持 windowTitlePattern 过滤）
    /// 3. 启动稳态校验
    /// 4. 清理 observer（一次性）
    private func handleAXWindowCreated(pid: pid_t, element: AXUIElement) {
        guard let observation = pendingAXObservations[pid] else {
            // 没有对应的待处理观察（可能已被清理），忽略
            return
        }
        let targetFrame = observation.targetFrame
        let titlePattern = observation.titlePattern

        logger.debug("AXObserver 检测到新窗口: pid=\(pid)")

        // 借鉴 yabai rule：按标题过滤窗口
        let matchedWindows = filterWindowsByTitle([element], pattern: titlePattern)
        guard !matchedWindows.isEmpty else {
            logger.debug("AXObserver 窗口标题不匹配 pattern: pid=\(pid) pattern=\(titlePattern ?? "<nil>", privacy: .public)")
            // 标题不匹配时不取消 observer，等待后续窗口创建
            return
        }

        // 取消兜底轮询 timer（AXObserver 已先命中）
        if let context = activeDetections[pid] {
            context.cancel()
            activeDetections.removeValue(forKey: pid)
        }
        stabilityCount.removeValue(forKey: pid)

        // 搬动匹配的窗口
        hideMoveUnhide(axWindows: matchedWindows, targetFrame: targetFrame)

        // 启动稳态校验（防回弹）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
        }

        // 清理 observer（窗口创建通知只需一次）
        removeAXObserver(for: pid)
        pendingAXObservations.removeValue(forKey: pid)
    }

    /// 移除指定 pid 的 AXObserver + RunLoopSource
    private func removeAXObserver(for pid: pid_t) {
        if let source = axRunLoopSources[pid] {
            // RT158: 使用 CFRunLoopGetMain() 而非 CFRunLoopGetCurrent()，
            //        source 加在主 RunLoop 上，必须从主 RunLoop 移除
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            axRunLoopSources.removeValue(forKey: pid)
        }
        if let observer = axObservers[pid] {
            let appElement = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(observer, appElement, kAXWindowCreatedNotification as CFString)
            axObservers.removeValue(forKey: pid)
        }
    }

    // MARK: - pinToScreen 窗口移动事件驱动
    // FIX-响应慢: C 回调直接 DispatchQueue.main.async 调用，不再需要 NotificationCenter 桥接

    /// 为 pinned app 创建 AXObserver，订阅 kAXMovedNotification
    /// 窗口被拖动时立即触发检查，响应速度从 100ms 轮询 → 事件驱动（<10ms）
    private func setupPinObserver(for pid: pid_t) {
        // 已存在则跳过
        guard pinObservers[pid] == nil else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, Self.pinObserverCallback, &observer)

        guard result == .success, let observer = observer else {
            logger.debug("pinObserver AXObserverCreate 失败: pid=\(pid) result=\(result.rawValue)")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let addResult = AXObserverAddNotification(
            observer, appElement,
            kAXMovedNotification as CFString,
            nil
        )
        if addResult != .success {
            logger.debug("pinObserver AXObserverAddNotification 失败: pid=\(pid) result=\(addResult.rawValue)")
            return
        }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        // RT159: 显式使用 CFRunLoopGetMain()，与 removePinObserver/deinit 中移除保持一致
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        pinObservers[pid] = observer
        pinRunLoopSources[pid] = runLoopSource
        logger.debug("pinObserver 已创建: pid=\(pid)")
    }

    /// pinToScreen AXObserver C 回调——窗口移动通知
    /// FIX-响应慢: 直接 DispatchQueue.main.async 调用，不走 NotificationCenter 桥接（省 ~10-20ms）
    private static let pinObserverCallback: AXObserverCallback = { observer, element, notification, _ in
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else { return }

        let notificationStr = notification as String
        guard notificationStr == kAXMovedNotification as String else { return }

        DispatchQueue.main.async {
            WindowMover.shared?.handlePinWindowMoved(pid: pid)
        }
    }

    /// 窗口移动事件到达——检测拖拽状态后决定是否回弹
    /// FIX-拖拽检测: 通过检测鼠标左键是否按下来判断用户是否在拖拽窗口：
    ///     - 鼠标按下 → 用户正在拖拽，不回弹，记录 pid 等松手后检查
    ///     - 鼠标松开 → 用户已释放，立即检查回弹
    ///     松手检测通过 NSEvent.addGlobalMonitorForEvents(.leftMouseUp) 实现，比轮询更可靠
    private func handlePinWindowMoved(pid: pid_t) {
        // 启动期跳过
        guard !isPerformingInitialMove else { return }

        let windowID = "\(pid)-main"
        // 正在系统移动中时跳过
        guard !movingWindows.contains(windowID) else { return }

        // FIX-拖拽检测: 检测鼠标左键是否按下
        let isDragging = isMouseLeftButtonDown()

        if isDragging {
            // 用户正在拖拽——不回弹，记录 pid 等松手后检查
            pendingDragCheckPids.insert(pid)
            startGlobalMouseUpMonitor()
        } else {
            // 鼠标已松开——不是用户拖拽（可能是系统移动窗口），立即检查回弹
            performPinCheck(pid: pid)
        }
    }

    /// 启动全局鼠标松开事件监听（仅在有待检查的拖拽窗口时启动）
    private func startGlobalMouseUpMonitor() {
        guard globalMouseUpMonitor == nil else { return }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleGlobalMouseUp()
            }
        }
    }

    /// 全局鼠标松开回调——检查所有等待松手后回弹的窗口
    /// FIX: 松手后如果 pendingDragCheckPids 仍非空（多窗口拖拽场景），重新启动 monitor
    private func handleGlobalMouseUp() {
        // 移除当前监听
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }

        // 取出所有待检查的 pid
        let pidsToCheck = pendingDragCheckPids
        pendingDragCheckPids.removeAll()

        // 逐个检查回弹
        for pid in pidsToCheck {
            performPinCheck(pid: pid)
        }

        // FIX: 如果在检查过程中又有新的拖拽 move 事件（pendingDragCheckPids 重新非空），
        // 重新启动 monitor
        if !pendingDragCheckPids.isEmpty {
            startGlobalMouseUpMonitor()
        }
    }

    /// 检测鼠标左键是否按下
    /// 使用 NSEvent.pressedMouseButtons 查询当前鼠标按键状态，无副作用
    /// 返回值中 bit 0 = 左键，bit 1 = 右键，bit 2 = 中键
    private func isMouseLeftButtonDown() -> Bool {
        return NSEvent.pressedMouseButtons & (1 << 0) != 0
    }

    /// 防抖到期后执行实际的 pinToScreen 检查
    private func performPinCheck(pid: pid_t) {
        let windowID = "\(pid)-main"
        // 冷却期检查——刚被系统移动过的窗口，短时间内不再移动
        guard !lastMovedWindows.contains(windowID) else { return }

        // 快速路径——直接查 pinTargetCache
        if let cached = pinTargetCache[pid] {
            checkWindowPosition(pid: pid, screenFrame: cached.frame, targetFrame: cached.visibleFrame, appBundleID: "", screenID: cached.screenID, fastPath: true)
            return
        }

        // 兜底：缓存未命中时走完整路径
        checkSinglePinnedApp(pid: pid)
    }

    /// 检查单个 pinned app 的窗口位置（兜底路径，缓存未命中时使用）
    private func checkSinglePinnedApp(pid: pid_t) {
        guard let modelContext = modelContext else { return }

        // 找到该 pid 对应的 AppInfo
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.processIdentifier == pid }),
              let bundleID = app.bundleIdentifier else { return }

        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true && $0.pinToScreen == true && $0.bundleIdentifier == bundleID }
        )
        guard let appInfo = try? modelContext.fetch(descriptor).first else { return }

        let currentScreens = getCurrentScreenMappings()
        guard let resolved = resolveTargetFrame(for: appInfo, currentScreens: currentScreens) else { return }

        // FIX-响应慢: 只查单个 pid 的窗口，不扫描全部
        checkWindowPosition(pid: pid, screenFrame: resolved.frame, targetFrame: resolved.visibleFrame, appBundleID: appInfo.bundleIdentifier, screenID: resolved.id)
    }

    /// 移除指定 pid 的 pinToScreen observer
    private func removePinObserver(for pid: pid_t) {
        if let source = pinRunLoopSources[pid] {
            // RT154: 使用 CFRunLoopGetMain() 而非 CFRunLoopGetCurrent()，
            //        source 加在主 RunLoop 上，必须从主 RunLoop 移除
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            pinRunLoopSources.removeValue(forKey: pid)
        }
        if let observer = pinObservers[pid] {
            let appElement = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(observer, appElement, kAXMovedNotification as CFString)
            pinObservers.removeValue(forKey: pid)
        }
        // FIX-响应慢: 同步清理 pinTargetCache + pinWindowCache + pinWindowSizeCache + 拖拽检测
        pinTargetCache.removeValue(forKey: pid)
        pinWindowCache.removeValue(forKey: pid)
        pinWindowSizeCache.removeValue(forKey: pid)
        pendingDragCheckPids.remove(pid)
        // FIX: 如果没有待检查的拖拽窗口了，清理全局鼠标松开监听
        if pendingDragCheckPids.isEmpty, let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
    }

    /// 刷新所有 pinned app 的 pinObserver（配置变更时调用）
    /// 新增 pinToScreen → 创建 observer；取消 pinToScreen → 移除 observer
    /// FIX-响应慢: 同步构建 pinTargetCache，供 handlePinWindowMoved 快速路径使用
    private func refreshPinObservers() {
        guard let modelContext = modelContext else { return }

        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true && $0.pinToScreen == true }
        )
        let pinnedApps = (try? modelContext.fetch(descriptor)) ?? []

        let runningApps = NSWorkspace.shared.runningApplications
        var runningBundleIDs: Set<String> = []
        var bundleIDToPid: [String: pid_t] = [:]
        for app in runningApps {
            if let bid = app.bundleIdentifier {
                runningBundleIDs.insert(bid)
                bundleIDToPid[bid] = app.processIdentifier
            }
        }

        let currentScreens = getCurrentScreenMappings()

        // 需要监听的 pid 集合 + 构建 pinTargetCache
        var desiredPids: Set<pid_t> = []
        var newPinTargetCache: [pid_t: (frame: CGRect, visibleFrame: CGRect, screenID: UInt32)] = [:]
        for appInfo in pinnedApps {
            if runningBundleIDs.contains(appInfo.bundleIdentifier),
               let pid = bundleIDToPid[appInfo.bundleIdentifier] {
                desiredPids.insert(pid)
                setupPinObserver(for: pid)
                // FIX-响应慢: 预计算 targetFrame 并缓存
                if let resolved = resolveTargetFrame(for: appInfo, currentScreens: currentScreens) {
                    newPinTargetCache[pid] = (resolved.frame, resolved.visibleFrame, resolved.id)
                }
            }
        }
        pinTargetCache = newPinTargetCache

        // FIX: 先收集要移除的 pid，避免遍历中修改字典导致未定义行为
        let pidsToRemove = pinObservers.keys.filter { !desiredPids.contains($0) }
        for pid in pidsToRemove {
            removePinObserver(for: pid)
        }
    }

    /// P1: 监听 App 退出事件——及时清理该 App 的字典残留键
    /// 之前：仅依赖 timer tick 内 `isPIDStillOriginal()` 校验退出
    ///       在两次 tick 之间 App 退出且 tick 被 cancel 时 context 残留
    ///       `lastMovedWindows` / `movingWindows` / `previousWindowPositions` 留死键
    /// 现在：didTerminateApplicationNotification 立即清理所有与该 pid 相关的状态
    private func setupAppTerminationObserver() {
        appTerminationObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.handleAppTermination(pid: app.processIdentifier)
        }
    }

    /// 声明为 nonisolated 允许从 nonisolated 上下文（如 NotificationCenter observer）直接调用
    nonisolated private func handleAppTermination(pid: pid_t) {
        Task { @MainActor in
            // 取消检测上下文
            if let context = self.activeDetections.removeValue(forKey: pid) {
                context.cancel()
            }
            self.stabilityCount.removeValue(forKey: pid)
            // 清理 AXObserver
            self.removeAXObserver(for: pid)
            self.pendingAXObservations.removeValue(forKey: pid)
            // 清理 pinToScreen observer
            self.removePinObserver(for: pid)
            // 删除该 pid 前缀的所有 windowID 键
            let pidPrefix = "\(pid)-"
            // FIX: 先收集要删除的 key，避免遍历中修改字典导致未定义行为
            let posKeysToRemove = self.previousWindowPositions.keys.filter { $0.hasPrefix(pidPrefix) }
            for key in posKeysToRemove {
                self.previousWindowPositions.removeValue(forKey: key)
                self.previousWindowPositionsOrder.removeAll { $0 == key }
                self.previousWindowPositionsOrderSet.remove(key)
            }
            // movingWindows / lastMovedWindows / cooldownWorkItems 同理
            self.movingWindows = self.movingWindows.filter { !$0.hasPrefix(pidPrefix) }
            self.lastMovedWindows = self.lastMovedWindows.filter { !$0.hasPrefix(pidPrefix) }
            let cooldownKeysToRemove = self.cooldownWorkItems.keys.filter { $0.hasPrefix(pidPrefix) }
            for key in cooldownKeysToRemove {
                self.cooldownWorkItems[key]?.cancel()
                self.cooldownWorkItems.removeValue(forKey: key)
            }
        }
    }
    
    /// 设置应用启动观察者
    /// RT17: [weak self] 写在 Task 闭包内（Swift 捕获列表必须在闭包起始位置）
    /// FIX-启动不搬窗: 改为幂等注册——token 已存在则跳过，配合 startMonitoring 调用
    private func setupAppLaunchObserver() {
        guard appLaunchObserverToken == nil else { return }
        appLaunchObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }

            let pid = app.processIdentifier
            // R-209: 内层 Task 也加 [weak self] 捕获——Swift 6 strict concurrency
            //        下，inner Task 默认隐式捕获 outer closure 的 weak self 会触发
            //        `Reference to captured var 'self' in concurrently-executing code`
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleAppLaunch(bundleIdentifier: bundleID, pid: pid)
            }
        }
    }
    
    /// 处理应用启动
    /// RT12: 原用两步过滤（先 fetch enabled，再 in-memory filter bundleID）——
    ///       因为旧 SwiftData #Predicate 对 optional 字段兼容差；本路径 isEnabled/bundleID 都是
    ///       非 optional，可直接用组合谓词，SwiftData 直接在 SQLite 层过滤
    /// P2-谓词组合: 改为单条 FetchDescriptor，SQLite 直接命中 0-1 条记录
    ///             旧方案：每次 App 启动 fetch 全表 enabled Apps（用户配 50 个则 50 条全拉）
    ///             新方案：fetch 0-1 条
    /// RT66: hasTarget 包含 targetScreenName，与 moveAllOpenAppsToAssignedScreens / checkAndEnforcePinnedWindows 对齐
    private func handleAppLaunch(bundleIdentifier: String, pid: pid_t) {
        guard let modelContext = modelContext else { return }

        // P2-谓词组合: 组合谓词——isEnabled + bundleIdentifier 同时满足
        // 字段均为非 optional，#Predicate 兼容性稳定
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true && $0.bundleIdentifier == bundleIdentifier }
        )
        guard let appInfo = try? modelContext.fetch(descriptor).first else { return }

        // T6: pinToScreen 与 targetScreen 共享同一启动搬动入口，避免依赖 0.2s 定时器
        // RT66: 补 targetScreenName——早期版本只设 name 的 App 也能被 handleAppLaunch 捕获
        let hasTarget = appInfo.targetScreenID != nil
            || appInfo.targetScreenSerialNumber != nil
            || appInfo.targetScreenName != nil
        guard appInfo.pinToScreen || hasTarget else { return }

        // 获取当前屏幕信息
        let currentScreens = getCurrentScreenMappings()

        // RT69: 抽 resolveTargetFrame helper
        guard let resolved = resolveTargetFrame(for: appInfo, currentScreens: currentScreens) else {
            // RT31: 配置的屏幕全部匹配失败时输出日志，便于定位"配置屏幕已拔掉"
            // P2: 改用 Logger——自动避免未启用级别下的字符串构造
            logger.error("未找到 App 配置的目标屏幕: bundleID=\(bundleIdentifier, privacy: .public) targetScreenID=\(String(describing: appInfo.targetScreenID), privacy: .public) targetScreenSerialNumber=\(appInfo.targetScreenSerialNumber ?? "<nil>", privacy: .public) targetScreenName=\(appInfo.targetScreenName ?? "<nil>", privacy: .public)")
            return
        }

        logger.info("handleAppLaunch 解析目标屏幕: bundleID=\(bundleIdentifier, privacy: .public) screenID=\(resolved.id) frame=\(NSStringFromRect(resolved.frame), privacy: .public) visibleFrame=\(NSStringFromRect(resolved.visibleFrame), privacy: .public)")

        // 借鉴 yabai：AXObserver 事件驱动作为主检测路径（零轮询，窗口创建即触发）
        // 双链轮询降级为兜底（AXObserver 对少数 App 如 Electron 可能不触发）
        setupAXObserver(for: pid, targetFrame: resolved.visibleFrame, titlePattern: appInfo.windowTitlePattern)

        // 兜底：启动双链轮询（CG 33ms + AX 100ms），AXObserver 先命中时会自动取消轮询
        // 对 Electron 等不触发 kAXWindowCreatedNotification 的 App 仍需轮询
        earlyWindowCatcher(pid: pid, targetFrame: resolved.visibleFrame, titlePattern: appInfo.windowTitlePattern)

        // FIX-启动不搬窗: 延迟 AX 兜底——部分 App（如微信）启动时 AXObserver/CGWindowList 都检测不到窗口，
        // 但在几百 ms 后 AX 窗口属性可用。这里在 0.5s 和 1.5s 再各尝试一次直接 AX 搬窗。
        scheduleAXFallbackMove(pid: pid, targetFrame: resolved.visibleFrame, delays: [0.5, 1.5])
    }

    /// FIX-启动不搬窗: 应用启动后的延迟 AX 兜底搬窗
    /// 不依赖 kAXWindowCreatedNotification 和 CGWindowList，而是定时直接用 AX 读取窗口并检查位置
    /// RT160: workItems 保存到 axFallbackWorkItems，stopMonitoring 时可取消
    private func scheduleAXFallbackMove(pid: pid_t, targetFrame: CGRect, delays: [TimeInterval]) {
        for delay in delays {
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // 窗口已经不在运行或已搬到目标屏则跳过
                guard NSRunningApplication(processIdentifier: pid) != nil else { return }
                let appElement = AXUIElementCreateApplication(pid)
                var windowsValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                      let axWindows = windowsValue as? [AXUIElement], !axWindows.isEmpty else {
                    logger.info("AX 兜底: 未获取到窗口 pid=\(pid, privacy: .public)")
                    return
                }
                guard let mainWindow = self.pickMainWindow(from: axWindows) else {
                    logger.info("AX 兜底: 挑不出主窗口 pid=\(pid, privacy: .public)")
                    return
                }
                var positionValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(mainWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
                      AXUIElementCopyAttributeValue(mainWindow, kAXSizeAttribute as CFString, &sizeValue) == .success else {
                    return
                }
                var currentPosition = CGPoint.zero
                var currentSize = CGSize.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &currentPosition)
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &currentSize)
                let currentBounds = CGRect(origin: currentPosition, size: currentSize)
                if self.isBoundsInTargetFrame(currentBounds, targetFrame: targetFrame) {
                    logger.info("AX 兜底: 窗口已在目标屏幕 pid=\(pid, privacy: .public)")
                    return
                }
                logger.info("AX 兜底: 窗口不在目标屏幕，执行搬窗 pid=\(pid, privacy: .public) current=\(NSStringFromRect(currentBounds), privacy: .public) target=\(NSStringFromRect(targetFrame), privacy: .public)")
                self.hideMoveUnhide(axWindows: [mainWindow], targetFrame: targetFrame)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
                }
            }
            axFallbackWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
    
    /// 设置 AX 窗口的 hidden 属性
    /// - Returns: 是否设置成功（不响应 hidden 的 App 会返回 false）
    @discardableResult
    private func setAXWindowHidden(_ window: AXUIElement, hidden: Bool) -> Bool {
        let value: CFBoolean = hidden ? kCFBooleanTrue : kCFBooleanFalse
        return AXUIElementSetAttributeValue(window, kAXHiddenAttribute as CFString, value) == .success
    }

    /// 对一组窗口执行 hide → move → unhide。
    /// unhide 失败时（少数 App 在 hidden=true → move → hidden=false 时第二次 set 会失败），
    /// 100ms 后兜底重试一次，避免窗口永久不可见。
    /// hide 之前会先校验窗口仍可访问（位置属性可读），已被销毁的窗口不参与 hide。
    /// RT5: unhide retry 的 workItem 在执行完成后自清理；移动 cooldown 用 cooldownKey(...) 统一生成 key
    /// FIX-启动不搬窗: 对不支持 hidden 属性的 App（如微信），hidden 设置失败后直接走 move-only 路径
    private func hideMoveUnhide(axWindows: [AXUIElement], targetFrame: CGRect) {
        // 1) 仅对"还活着"的窗口走 hide 路径，已销毁的窗口直接跳过
        let alive: [AXUIElement] = axWindows.filter { isAXWindowAlive($0) }

        // FIX-启动不搬窗: 记录 hidden 设置是否成功，失败的窗口直接 move 不尝试 unhide
        var hiddenSucceeded: [AXUIElement: Bool] = [:]
        for window in alive {
            let ok = setAXWindowHidden(window, hidden: true)
            hiddenSucceeded[window] = ok
            if !ok {
                logger.debug("hideMoveUnhide: hidden=true 设置失败，该窗口将走 move-only")
            }
        }

        for window in alive { moveWindowToFrameImmediate(window, targetFrame: targetFrame) }

        for window in alive {
            guard hiddenSucceeded[window] == true else { continue }
            if !setAXWindowHidden(window, hidden: false) {
                let key = cooldownKey(axWindow: window)
                // RT5: 覆盖前先取消旧 workItem，避免旧的不必要的执行
                cooldownWorkItems[key]?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    // P3: 检查窗口是否仍然存活——避免对已销毁窗口执行 unhide
                    guard let self = self, self.isAXWindowAlive(window) else {
                        self?.cooldownWorkItems.removeValue(forKey: key)
                        return
                    }
                    self.setAXWindowHidden(window, hidden: false)
                    // RT5: unhide retry 自清理 dict
                    self.cooldownWorkItems.removeValue(forKey: key)
                }
                cooldownWorkItems[key] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
            }
        }
    }

    /// RT5: 统一生成 cooldownWorkItems 的 key
    /// - 用 windowID: 移动冷却
    /// - 用 AXUIElement pointer: unhide retry 冷却
    /// R-129: 改用 Unmanaged opaque pointer 作为 key——AXUIElement 生命周期内稳定，
    ///        释放后被新对象复用理论风险，注释说明
    private func cooldownKey(windowID: String? = nil, axWindow: AXUIElement? = nil) -> String {
        if let wid = windowID { return "move:\(wid)" }
        if let win = axWindow {
            // R-129: 用 opaque pointer（AXUIElement CFTypeRef 内存地址）替代 ObjectIdentifier.hashValue
            let ptr = Unmanaged<AXUIElement>.passUnretained(win).toOpaque()
            return "unhide:\(ptr)"
        }
        return "unknown"
    }

    /// 校验 AX 窗口仍可访问（位置属性可读即为"活着"）。
    /// 用于 hide 之前避免对刚被销毁的窗口调用无意义的 setter。
    private func isAXWindowAlive(_ window: AXUIElement) -> Bool {
        var posVal: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posVal) == .success
    }

    /// 通过 CGWindowList 查找指定 PID 的第一个"普通 on-screen"窗口 bounds
    /// 过滤条件：ownerPID 匹配 + layer == 0（普通窗口，过滤菜单栏/系统浮层）
    ///         + alpha > 0（过滤完全透明的辅助层）+ 宽高 ≥ 50（过滤最小化/瞬时态）
    /// RT80: 优先返回 kCGWindowName 非空的窗口（避免极小工具窗口被误选为主窗口）
    /// C1: 改 .optionAll → .optionOnScreenOnly——只取当前可见窗口，跳过离屏渲染层；
    ///     单次返回数据量 ↓，CGWindowListCopyWindowInfo 成本 ↓
    private func findOnScreenWindow(for pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var bestTitledBounds: CGRect? = nil
        var bestTitledArea: CGFloat = 0
        var bestUnconditionalBounds: CGRect? = nil
        var bestUnconditionalArea: CGFloat = 0

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }
            // 仅普通窗口（layer 0 为普通窗口，浮层/菜单栏是更高 layer）
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            // 过滤完全透明窗口（辅助层 / 离屏渲染层）
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0 {
                continue
            }
            // bounds 字段以 CFDictionary 形式给出 {X, Y, Width, Height}
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat else {
                continue
            }
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            let area = width * height

            // RT80: 优先有 title 的窗口（kCGWindowName 非空）
            let title = window[kCGWindowName as String] as? String
            let hasTitle = !(title?.isEmpty ?? true)

            if hasTitle {
                if area > bestTitledArea {
                    bestTitledBounds = bounds
                    bestTitledArea = area
                }
            } else if width >= 50 && height >= 50 {
                // 兜底：无 title 但满足最小尺寸时，记录最大无 title 窗口
                if area > bestUnconditionalArea {
                    bestUnconditionalBounds = bounds
                    bestUnconditionalArea = area
                }
            }
        }
        return bestTitledBounds ?? bestUnconditionalBounds
    }

    /// FIX-响应慢: 一次性获取所有 on-screen 主窗口并按 pid 分组，避免每个 App 单独调用 CGWindowListCopyWindowInfo
    /// 逻辑与 findOnScreenWindow 一致：优先有 title 的最大面积窗口，兜底无 title 但尺寸 ≥ 50 的最大面积窗口
    private func fetchAllOnScreenMainWindows() -> [pid_t: CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var bestTitled: [pid_t: (bounds: CGRect, area: CGFloat)] = [:]
        var bestUntitled: [pid_t: (bounds: CGRect, area: CGFloat)] = [:]

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat else { continue }

            let bounds = CGRect(x: x, y: y, width: width, height: height)
            let area = width * height

            let title = window[kCGWindowName as String] as? String
            let hasTitle = !(title?.isEmpty ?? true)

            if hasTitle {
                if area > (bestTitled[ownerPID]?.area ?? 0) {
                    bestTitled[ownerPID] = (bounds, area)
                }
            } else if width >= 50 && height >= 50 {
                if area > (bestUntitled[ownerPID]?.area ?? 0) {
                    bestUntitled[ownerPID] = (bounds, area)
                }
            }
        }

        var result: [pid_t: CGRect] = [:]
        let allPIDs = Set(bestTitled.keys).union(bestUntitled.keys)
        for pid in allPIDs {
            result[pid] = bestTitled[pid]?.bounds ?? bestUntitled[pid]?.bounds
        }
        return result
    }

    /// 在 AX 窗口列表中按 (position, size) 容差匹配，拿到与 CGWindowList 同一窗口对应的 AXUIElement
    /// 容差 1.0 像素，覆盖浮点精度问题
    private func matchAXWindow(for pid: pid_t, targetBounds: CGRect) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )

        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            var posVal: CFTypeRef?
            var sizeVal: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posVal) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeVal) == .success,
                  let posVal = posVal, let sizeVal = sizeVal else {
                continue
            }

            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(posVal as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else {
                continue
            }

            if abs(position.x - targetBounds.origin.x) < 1.0,
               abs(position.y - targetBounds.origin.y) < 1.0,
               abs(size.width - targetBounds.width) < 1.0,
               abs(size.height - targetBounds.height) < 1.0 {
                return window
            }
        }
        return nil
    }

    /// 早期窗口检测 + 移动 + 稳态校验（替代旧的 pollForWindows）
    /// Phase A: 双链并行检测窗口（CGWindowList 16ms + AX 100ms 兜底），任一链先命中即触发 Phase B
    /// Phase B: 拿到 AXUIElement 后调用 moveWindowToFrameImmediate
    /// Phase C: 1.5-2s 内每 100ms 校验一次，发现回弹立刻再搬
    /// RT1: 每个 pid 拥有独立 DetectionContext，timer 写入 context 自身
    /// RT103: 记录首次拿到 pid 时的 launchDate，timer 校验防止 PID 复用误命中
    private func earlyWindowCatcher(pid: pid_t, targetFrame: CGRect, titlePattern: String? = nil) {
        // 同 pid 已有上下文在跑 → 取消旧上下文（用户重启 App 的场景）
        if let existing = activeDetections[pid] {
            existing.cancel()
            activeDetections.removeValue(forKey: pid)
        }
        // RT103: 抓取 launchDate 用于 PID 复用防御
        let launchDate = NSRunningApplication(processIdentifier: pid)?.launchDate
        let detectionTimeout: TimeInterval = 5.0
        let context = DetectionContext(pid: pid, targetFrame: targetFrame, launchDate: launchDate, titlePattern: titlePattern)
        activeDetections[pid] = context

        // 链 A：CGWindowList 高频轮询
        startCGDetectionTimer(context: context, timeout: detectionTimeout)
        // 链 B：AX 100ms 兜底（无 Screen Recording 权限时仍能工作）
        startAXDetectionTimer(context: context, timeout: detectionTimeout)
    }

    /// 链 A：CGWindowList 高频轮询（DispatchSourceTimer 实现，无栈增长）
    private func startCGDetectionTimer(context: DetectionContext, timeout: TimeInterval) {
        let pid = context.pid
        let targetFrame = context.targetFrame
        let stopFlag = context.stopFlag
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = cgDetectionInterval
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(interval * 1000)), leeway: .milliseconds(2))
        let startTime = Date()
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if stopFlag.isSet { self.cancelDetectionContext(pid: pid); return }
            if Date().timeIntervalSince(startTime) > timeout { self.cancelDetectionContext(pid: pid); return }
            // RT13: 0-PID 防御；RT103: PID 复用防御（launchDate 校验）
            guard pid > 0, context.isPIDStillOriginal() else {
                self.cancelDetectionContext(pid: pid); return
            }
            // T5: 拓扑变化感知——目标屏不再存在则主动放弃
            guard self.isTargetScreenAvailable(targetFrame) else { self.cancelDetectionContext(pid: pid); return }

            if let bounds = self.findOnScreenWindow(for: pid) {
                if stopFlag.trySet() {
                    // R-128: 停止 CG/AX timer 但保留 context（供 startStabilityCheck 使用 originalLaunchDate）
                    self.stopDetectionTimers(pid: pid)
                    self.onWindowDetected(pid: pid, targetFrame: targetFrame, initialBounds: bounds)
                }
                return
            }
        }
        // RT81: 覆盖前 cancel 旧 timer
        context.cgTimer?.cancel()
        context.cgTimer = timer
        timer.resume()
    }

    /// 链 B：AX 100ms 兜底轮询（DispatchSourceTimer 实现）
    private func startAXDetectionTimer(context: DetectionContext, timeout: TimeInterval) {
        let pid = context.pid
        let targetFrame = context.targetFrame
        let stopFlag = context.stopFlag
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        let startTime = Date()
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if stopFlag.isSet { self.cancelDetectionContext(pid: pid); return }
            if Date().timeIntervalSince(startTime) > timeout { self.cancelDetectionContext(pid: pid); return }
            // RT13: 0-PID 防御；RT103: PID 复用防御
            guard pid > 0, context.isPIDStillOriginal() else {
                self.cancelDetectionContext(pid: pid); return
            }
            // T5: 拓扑变化感知
            guard self.isTargetScreenAvailable(targetFrame) else { self.cancelDetectionContext(pid: pid); return }

            let appElement = AXUIElementCreateApplication(pid)
            var windowsValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
            if result == .success, let windows = windowsValue as? [AXUIElement], !windows.isEmpty {
                if stopFlag.trySet() {
                    // R-128: 停止 AX timer 但保留 context
                    self.stopDetectionTimers(pid: pid)
                    self.onWindowDetected(pid: pid, targetFrame: targetFrame, axWindows: windows)
                }
                return
            }
        }
        // RT81: 覆盖前 cancel 旧 timer
        context.axTimer?.cancel()
        context.axTimer = timer
        timer.resume()
    }

    /// 取消某个 pid 的检测上下文（含所有 timer）
    /// RT70: 简化参数——所有调用点都传 cancelTimers: true，参数冗余
    /// RT62: 同步清理 stabilityCount，避免 cancel 后遗留 pid 计数
    private func cancelDetectionContext(pid: pid_t) {
        guard let context = activeDetections[pid] else { return }
        context.cancel()
        activeDetections.removeValue(forKey: pid)
        stabilityCount.removeValue(forKey: pid)
    }

    /// R-128: 停止 CG/AX 检测 timer 但保留 context——供 startStabilityCheck 后续
    ///     使用 originalLaunchDate 做 PID 复用防御；context 仍留在 activeDetections 中
    private func stopDetectionTimers(pid: pid_t) {
        guard let context = activeDetections[pid] else { return }
        context.cgTimer?.cancel(); context.cgTimer = nil
        context.axTimer?.cancel(); context.axTimer = nil
        context.stopFlag.set()
    }

    /// 校验目标屏幕 frame 仍在当前屏幕拓扑中
    /// RT56: visibleFrame 容差（避免 Dock 高度变化时误判）
    private static let screenFrameTolerance: CGFloat = 1.0

    /// 判断目标屏幕 frame 是否仍可识别
    private func isTargetScreenAvailable(_ targetFrame: CGRect) -> Bool {
        return getCurrentScreenMappings().contains { abs($0.frame.minX - targetFrame.minX) < Self.screenFrameTolerance
            && abs($0.frame.minY - targetFrame.minY) < Self.screenFrameTolerance
            && abs($0.frame.width - targetFrame.width) < Self.screenFrameTolerance
            && abs($0.frame.height - targetFrame.height) < Self.screenFrameTolerance
        }
    }

    /// 窗口被检测到（CG 链命中）：用 bounds 匹配 AXUIElement，再移动
    /// R-127: PID 复用防御——通过 activeDetections[pid] 内的 originalLaunchDate 校验
    /// R-150: matchAXWindow 拿不到时 silent return + logger.error——避免误搬 IDE 等多窗口 App
    ///        的辅助窗口（Navigator/Inspector/Outline），不再回退搬动所有 AX 窗口
    private func onWindowDetected(pid: pid_t, targetFrame: CGRect, initialBounds: CGRect) {
        // R-127: PID 复用防御——context 仍在 activeDetections（stopDetectionTimers 未删除）
        if let context = activeDetections[pid], !context.isPIDStillOriginal() {
            // P2: 改用 Logger——热路径日志懒插值
            logger.error("onWindowDetected(CG) PID 已被复用: pid=\(pid), 放弃搬动")
            cancelDetectionContext(pid: pid)
            return
        }

        // 用 CG bounds 去 AX 列表里匹配同一个窗口
        if let axWindow = matchAXWindow(for: pid, targetBounds: initialBounds) {
            // hide → move → unhide，让用户看不到"错误屏幕位置"那一两帧
            hideMoveUnhide(axWindows: [axWindow], targetFrame: targetFrame)
        } else {
            // FIX-启动不搬窗: CG/AX 精确匹配失败时（如微信），回退到 pickMainWindow
            //   从 AX 窗口列表中挑主窗口搬动，与 onWindowDetected(AX) 路径保持一致
            logger.warning("onWindowDetected(CG) matchAXWindow 失败，回退 pickMainWindow: pid=\(pid) initialBounds=\(NSStringFromRect(initialBounds), privacy: .public)")
            let appElement = AXUIElementCreateApplication(pid)
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let axWindows = windowsValue as? [AXUIElement] {
                let titlePattern = activeDetections[pid]?.titlePattern
                let filteredWindows = filterWindowsByTitle(axWindows, pattern: titlePattern)
                if let mainWindow = pickMainWindow(from: filteredWindows) {
                    hideMoveUnhide(axWindows: [mainWindow], targetFrame: targetFrame)
                } else {
                    logger.error("onWindowDetected(CG) 回退 pickMainWindow 也失败: pid=\(pid), 放弃搬动")
                }
            } else {
                logger.error("onWindowDetected(CG) matchAXWindow 失败且 AX 窗口列表获取失败: pid=\(pid), 放弃搬动")
            }
        }

        // RT2: 延迟 120ms 让 unhide 100ms 重试先完成，避免"刚搬完又再搬一次"回弹
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
        }
    }

    /// 窗口被检测到（AX 链命中）：CG 兜底链不命中时使用
    /// R-127: PID 复用防御
    /// R-186: 不再搬动**所有** AX 窗口——多窗口 App（IDE/Photoshop）会把辅助窗口全部居中到
    ///        targetFrame 中心点重叠。改为：挑**主窗口**（有 title 或面积最大）搬动，其他辅助窗口不动
    /// 借鉴 yabai rule：支持 windowTitlePattern 按标题过滤
    private func onWindowDetected(pid: pid_t, targetFrame: CGRect, axWindows: [AXUIElement]) {
        if let context = activeDetections[pid], !context.isPIDStillOriginal() {
            // P2: 改用 Logger——热路径日志懒插值
            logger.error("onWindowDetected(AX) PID 已被复用: pid=\(pid), 放弃搬动")
            cancelDetectionContext(pid: pid)
            return
        }

        // 借鉴 yabai rule：按标题过滤窗口
        let titlePattern = activeDetections[pid]?.titlePattern
        let filteredWindows = filterWindowsByTitle(axWindows, pattern: titlePattern)
        guard !filteredWindows.isEmpty else {
            logger.debug("onWindowDetected(AX) 窗口标题不匹配 pattern: pid=\(pid) pattern=\(titlePattern ?? "<nil>", privacy: .public)")
            return
        }

        // R-186: 挑主窗口——优先有 title 的（IDE 主窗口/Safari 标签等），否则挑面积最大的
        if let mainWindow = pickMainWindow(from: filteredWindows) {
            hideMoveUnhide(axWindows: [mainWindow], targetFrame: targetFrame)
        } else {
            // P2: 改用 Logger——热路径日志懒插值
            logger.error("onWindowDetected(AX) 挑不出主窗口: pid=\(pid) windowsCount=\(filteredWindows.count), 放弃搬动")
        }

        // RT2: 延迟 120ms 让 unhide 重试先完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
        }
    }

    /// 借鉴 yabai rule 系统：按窗口标题过滤
    /// windowTitlePattern 为 nil 或空 = 匹配所有窗口（默认行为，向后兼容）
    /// 非空 = 仅匹配标题包含该字符串的窗口（大小写不敏感）
    /// 返回匹配的窗口列表；无匹配返回空数组
    private func filterWindowsByTitle(_ windows: [AXUIElement], pattern: String?) -> [AXUIElement] {
        guard let pattern = pattern, !pattern.isEmpty else {
            return windows // 无 pattern = 匹配所有
        }
        return windows.filter { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String, !title.isEmpty else {
                return false // 无标题的窗口在 pattern 模式下不匹配
            }
            return title.localizedCaseInsensitiveContains(pattern)
        }
    }

    /// R-186: 挑主窗口——优先有 title 的；无 title 时挑面积最大的；都拿不到返回 nil
    private func pickMainWindow(from windows: [AXUIElement]) -> AXUIElement? {
        var withTitle: [(AXUIElement, CGRect)] = []
        var maxArea: CGFloat = 0
        var largestWindow: AXUIElement?

        for window in windows {
            var posValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            let posOK = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success
            let sizeOK = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
            guard posOK, sizeOK, let posVal = posValue, let sizeVal = sizeValue else { continue }

            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
            let bounds = CGRect(origin: pos, size: size)

            // 拿 title
            var titleValue: CFTypeRef?
            let hasTitle = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success
                && titleValue != nil
                && (titleValue as? String)?.isEmpty == false

            if hasTitle {
                withTitle.append((window, bounds))
            }
            let area = bounds.width * bounds.height
            if area > maxArea {
                maxArea = area
                largestWindow = window
            }
        }

        // 优先有 title 的——多个有 title 时挑面积最大的
        if !withTitle.isEmpty {
            return withTitle.max { ($0.1.width * $0.1.height) < ($1.1.width * $1.1.height) }?.0
        }
        // 否则挑面积最大的
        if let main = largestWindow, maxArea > 0 {
            return main
        }
        return nil
    }

    /// 稳态校验：1.5-2s 内每 100ms 检查一次，发现回弹立刻再搬，连续 3 次稳定停止
    /// RT1: stabilityTimer 写入 context 自身；RT2: 延迟 120ms 让 unhide 重试先完成
    /// R-128/R-132: 用 context.isPIDStillOriginal() 替代旧 NSRunningApplication 检查；
    ///              命中稳定或超时后完整清理 activeDetections + stabilityCount
    private func startStabilityCheck(pid: pid_t, targetFrame: CGRect) {
        guard let context = activeDetections[pid] else { return }
        stabilityCount[pid] = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let startTime = Date()
        let maxDuration: TimeInterval = 2.0
        let requiredStableCount = 3

        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // RT1: 上下文已被取消则退出
            guard self.activeDetections[pid] != nil else { timer.cancel(); return }
            // RT13/R-128: 0-PID 防御 + PID 复用防御（用 context 内的 originalLaunchDate）
            guard pid > 0, context.isPIDStillOriginal() else {
                timer.cancel()
                self.cancelDetectionContext(pid: pid)
                return
            }
            if Date().timeIntervalSince(startTime) > maxDuration {
                timer.cancel()
                // R-128: 超时分支也清理 activeDetections + stabilityCount，避免 context 累积
                self.activeDetections[pid]?.stabilityTimer = nil
                self.activeDetections.removeValue(forKey: pid)
                self.stabilityCount.removeValue(forKey: pid)
                return
            }
            // T5: 拓扑变化感知
            guard self.isTargetScreenAvailable(targetFrame) else { timer.cancel(); return }

            let currentBounds = self.findOnScreenWindow(for: pid)
            let isStable = currentBounds.map { self.isBoundsInTargetFrame($0, targetFrame: targetFrame) } ?? false

            if isStable {
                self.stabilityCount[pid, default: 0] += 1
                if self.stabilityCount[pid, default: 0] >= requiredStableCount {
                    timer.cancel()
                    // RT33/R-128: 命中稳定后完整清理——清 timer 引用 + 移除 context + 清 stabilityCount
                    self.activeDetections[pid]?.stabilityTimer = nil
                    self.activeDetections.removeValue(forKey: pid)
                    self.stabilityCount.removeValue(forKey: pid)
                    return
                }
            } else {
                self.stabilityCount[pid] = 0
                // 回弹：重新搬（hide → move → unhide）
                if let bounds = currentBounds,
                   let axWindow = self.matchAXWindow(for: pid, targetBounds: bounds) {
                    self.hideMoveUnhide(axWindows: [axWindow], targetFrame: targetFrame)
                } else if let bounds = currentBounds {
                    // RT153: matchAXWindow 精确匹配失败时，回退到 pickMainWindow 兜底
                    //   与 onWindowDetected(CG) 路径保持一致
                    let appElement = AXUIElementCreateApplication(pid)
                    var windowsValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                       let axWindows = windowsValue as? [AXUIElement],
                       let mainWindow = self.pickMainWindow(from: axWindows) {
                        self.hideMoveUnhide(axWindows: [mainWindow], targetFrame: targetFrame)
                    } else {
                        logger.error("startStabilityCheck 回弹: matchAXWindow 和 pickMainWindow 均失败: pid=\(pid), 放弃重新搬动")
                    }
                }
            }
        }
        context.stabilityTimer = timer
        timer.resume()
    }

    /// 判断窗口是否"在目标屏合理位置"：窗口中心点在 visibleFrame 内 AND 窗口至少有 50% 在 visibleFrame 内
    /// FIX-自由移动: 改用"中心点 AND 50%面积"双条件判定
    ///     旧逻辑 90% 面积重叠过严：窗口靠近菜单栏/Dock 时重叠率低于 90% 被误判为"不在目标屏"，
    ///     导致 pinToScreen 应用在指定屏幕内也无法自由拖动。
    ///     改为"中心点 AND 50%面积"：
    ///     - 中心点：保证窗口主体在正确屏幕上不误判
    ///     - 50% 面积：避免窗口被 macOS 调整到奇怪位置（中心点在内但窗口大部分在屏外）时不被检测
    ///     50% 阈值允许窗口大部分超出 visibleFrame（如一半在屏外），但不会让窗口大部分在屏外
    private func isBoundsInTargetFrame(_ bounds: CGRect, targetFrame: CGRect) -> Bool {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // 中心点在 visibleFrame 内——窗口主体在正确屏幕
        guard targetFrame.contains(center) else { return false }
        // 窗口至少有 50% 面积在 visibleFrame 内——窗口没有大部分在屏外
        let overlapRatio = windowOverlapRatio(bounds, targetFrame: targetFrame)
        return overlapRatio >= 0.5
    }

    /// 计算窗口与目标屏 visibleFrame 的重叠面积占比
    private func windowOverlapRatio(_ bounds: CGRect, targetFrame: CGRect) -> CGFloat {
        let intersection = bounds.intersection(targetFrame)
        if intersection.isNull || intersection.isEmpty { return 0 }
        let windowArea = bounds.width * bounds.height
        guard windowArea > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        return intersectionArea / windowArea
    }

    /// FIX-启动不搬窗: CGWindowList 看不到窗口时，直接通过 AX API 获取并搬动窗口
    /// - Returns: 是否成功找到并尝试搬动至少一个 AX 窗口
    /// RT161: 只搬主窗口（与 onWindowDetected(AX) 路径一致），
    ///        避免多窗口 App 的辅助窗口被误搬
    private func moveAXWindowsToTargetFrame(for pid: pid_t, targetFrame: CGRect) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard axResult == .success, let axWindows = windowsValue as? [AXUIElement], !axWindows.isEmpty else {
            return false
        }

        // RT161: 只挑主窗口搬动，不搬辅助窗口
        guard let mainWindow = pickMainWindow(from: axWindows) else {
            return false
        }

        // 校验主窗口仍可访问
        guard isAXWindowAlive(mainWindow) else { return false }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(mainWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              positionValue != nil,
              AXUIElementCopyAttributeValue(mainWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              sizeValue != nil else { return false }

        logger.debug("启动搬窗: AX 直接搬主窗口 pid=\(pid, privacy: .public)")
        hideMoveUnhide(axWindows: [mainWindow], targetFrame: targetFrame)
        startStabilityCheck(pid: pid, targetFrame: targetFrame)
        return true
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func startMonitoring() -> Bool {
        guard !isMonitoring else { return true }

        if !AXIsProcessTrusted() {
            requestAccessibilityPermission()
            return false
        }

        isMonitoring = true

        // FIX-启动不搬窗: 在 startMonitoring 中注册应用启动监听，确保不丢失 SwallowScreen 启动后
        //   1s 延迟期间发生的应用启动通知。去重：token 已存在则跳过。
        setupAppLaunchObserver()

        // RT147: 入口完整状态重置，保证幂等（防止 stopMonitoring 中途失败时状态不一致）
        lastAppsFingerprint = 0
        cachedPinnedApps = []
        isPerformingInitialMove = false
        moveAllAppsTask?.cancel()
        moveAllAppsTask = nil
        lastMovedWindows.removeAll()
        previousWindowPositions.removeAll()
        previousWindowPositionsOrder.removeAll()
        // R-151: 同步清配套 Set
        previousWindowPositionsOrderSet.removeAll()
        movingWindows.removeAll()
        stabilityCount.removeAll()
        for item in cooldownWorkItems.values { item.cancel() }
        cooldownWorkItems.removeAll()

        // RT74: 启动期标志开启；checkAndEnforcePinnedWindows 期间会跳过 pinToScreen 分支
        isPerformingInitialMove = true
        // RT25: 外层 DispatchQueue.main.async 已保证主线程，移除冗余
        // RT15: 直接在主线程上设置 timer，Timer.scheduledTimer 已自动加入 default runloop
        // RT53: 启动期分批串行，避免瞬时 fan-out 过多 DispatchSourceTimer
        // RT65: task 句柄保存到 moveAllAppsTask，stopMonitoring 中可取消
        moveAllAppsTask = Task { @MainActor [weak self] in
            await self?.moveAllOpenAppsToAssignedScreens()
            // 完成时清标志位
            self?.isPerformingInitialMove = false
            self?.moveAllAppsTask = nil
        }

        // RT64: 改用 DispatchSourceTimer，与 RT59 permissionCheckTimer 风格一致
        let dispatchTimer = DispatchSource.makeTimerSource(queue: .main)
        dispatchTimer.schedule(deadline: .now() + self.checkInterval, repeating: self.checkInterval)
        dispatchTimer.setEventHandler { [weak self] in
            self?.checkAndEnforcePinnedWindows()
        }
        dispatchTimer.resume()
        self.timer = dispatchTimer
        return true
    }

    /// 应用启动时移动所有已打开应用到指定屏幕
    /// RT3: 改走 earlyWindowCatcher，与 handleAppLaunch 共享同一 hide/move/unhide + 稳态校验链路
    /// RT53: 改为 async，每批 earlyWindowCatcher 调用后 await Task.yield()，避免主 RunLoop 瞬时过载
    /// RT73: 每个 app 重新读 getCurrentScreenMappings()，启动期屏拓扑变化时仍能匹配最新屏幕
    /// FIX-启动不搬窗: 改为直接搬窗逻辑，与 checkAndEnforcePinnedWindows 风格一致
    private func moveAllOpenAppsToAssignedScreens() async {
        guard let modelContext = modelContext else { return }

        if !AXIsProcessTrusted() {
            return
        }

        // R-190: 谓词化——只拉启用 App，与 R-152 checkAndEnforcePinnedWindows 风格一致
        //        for 循环 guard appInfo.isEnabled 仍保留作防御（SwiftData 谓词不强制收紧）
        // R-214: FetchDescriptor 加 sortBy: \.bundleIdentifier——保证 fetch 顺序稳定
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.bundleIdentifier)]
        )
        guard let allApps = try? modelContext.fetch(descriptor) else { return }

        // FIX-启动不搬窗: 一次性获取所有 on-screen 主窗口，避免逐应用调用 CGWindowListCopyWindowInfo
        let allMainWindows = fetchAllOnScreenMainWindows()

        // FIX-启动不搬窗: 预构建 bundleID → pid 字典，避免循环内重复查找
        let runningApps = NSWorkspace.shared.runningApplications
        var bundleIDToPid: [String: pid_t] = [:]
        var pidToApp: [pid_t: NSRunningApplication] = [:]
        for app in runningApps {
            if let bid = app.bundleIdentifier {
                bundleIDToPid[bid] = app.processIdentifier
            }
            pidToApp[app.processIdentifier] = app
        }

        let currentScreens = getCurrentScreenMappings()

        // RT53: 每批最多处理 5 个 app 后让出主 RunLoop
        let batchSize = 5
        var processedInBatch = 0

        for appInfo in allApps {
            // 只有启用状态且设置了目标屏幕才处理
            guard appInfo.isEnabled else { continue }
            guard appInfo.targetScreenID != nil || appInfo.targetScreenSerialNumber != nil || appInfo.targetScreenName != nil else { continue }

            // RT69: 走 resolveTargetFrame helper
            guard let resolved = resolveTargetFrame(for: appInfo, currentScreens: currentScreens) else {
                // RT31: 同上，moveAllOpenAppsToAssignedScreens 路径也要打日志
                logger.error("未找到 App 配置的目标屏幕（启动时）: bundleID=\(appInfo.bundleIdentifier, privacy: .public) targetScreenID=\(String(describing: appInfo.targetScreenID), privacy: .public) targetScreenSerialNumber=\(appInfo.targetScreenSerialNumber ?? "<nil>", privacy: .public) targetScreenName=\(appInfo.targetScreenName ?? "<nil>", privacy: .public)")
                continue
            }

            // FIX-启动不搬窗: 从预构建字典查找 pid
            guard let pid = bundleIDToPid[appInfo.bundleIdentifier] else { continue }

            if let bounds = allMainWindows[pid] {
                // 有可见窗口——直接判断位置
                if isBoundsInTargetFrame(bounds, targetFrame: resolved.visibleFrame) {
                    // 窗口已在目标屏幕——跳过
                    logger.debug("启动搬窗: 已在目标屏幕，跳过: bundleID=\(appInfo.bundleIdentifier, privacy: .public)")
                    continue
                }
                // 窗口不在目标屏幕——复用 checkWindowPosition 直接搬窗
                logger.info("启动搬窗: 调用 checkWindowPosition: bundleID=\(appInfo.bundleIdentifier, privacy: .public) screenID=\(resolved.id) targetFrame=\(NSStringFromRect(resolved.visibleFrame), privacy: .public)")
                checkWindowPosition(pid: pid, screenFrame: resolved.frame, targetFrame: resolved.visibleFrame, appBundleID: appInfo.bundleIdentifier, screenID: resolved.id, prebuiltMainBounds: bounds)
            } else {
                // FIX-启动不搬窗: CGWindowList 看不到窗口时，直接通过 AX 获取窗口并搬动
                logger.debug("启动搬窗: CG 无可见窗口，尝试 AX 直接搬窗: bundleID=\(appInfo.bundleIdentifier, privacy: .public)")
                if !moveAXWindowsToTargetFrame(for: pid, targetFrame: resolved.visibleFrame) {
                    // AX 也拿不到窗口时，才回退到 earlyWindowCatcher 兜底
                    logger.debug("启动搬窗: AX 也无窗口，earlyWindowCatcher 兜底: bundleID=\(appInfo.bundleIdentifier, privacy: .public)")
                    earlyWindowCatcher(pid: pid, targetFrame: resolved.visibleFrame, titlePattern: appInfo.windowTitlePattern)
                }
            }

            processedInBatch += 1
            if processedInBatch >= batchSize {
                processedInBatch = 0
                // RT53: 让出主 RunLoop，避免 detection timer 全部堆积
                await Task.yield()
            }
        }
    }
    
    func stopMonitoring() {
        // RT65: 取消启动期 moveAllOpenAppsToAssignedScreens task
        moveAllAppsTask?.cancel()
        moveAllAppsTask = nil
        isPerformingInitialMove = false
        timer?.cancel()
        timer = nil
        isMonitoring = false
        lastMovedWindows.removeAll()
        previousWindowPositions.removeAll()
        previousWindowPositionsOrder.removeAll()
        // R-151: 同步清配套 Set
        previousWindowPositionsOrderSet.removeAll()
        movingWindows.removeAll()
        for context in activeDetections.values { context.cancel() }
        activeDetections.removeAll()
        stabilityCount.removeAll()
        for item in cooldownWorkItems.values { item.cancel() }
        cooldownWorkItems.removeAll()
        // RT160: 取消 AX 兜底延迟任务
        for item in axFallbackWorkItems { item.cancel() }
        axFallbackWorkItems.removeAll()
        lastAppsFingerprint = 0
        cachedPinnedApps = []
        // AXObserver 清理
        // RT157: 使用 CFRunLoopGetMain() 而非 CFRunLoopGetCurrent()，
        //        source 加在主 RunLoop 上，必须从主 RunLoop 移除
        let mainRunLoop = CFRunLoopGetMain()
        for (_, source) in axRunLoopSources {
            CFRunLoopRemoveSource(mainRunLoop, source, .defaultMode)
        }
        axRunLoopSources.removeAll()
        axObservers.removeAll()
        pendingAXObservations.removeAll()
        // pinToScreen observer 清理
        for (_, source) in pinRunLoopSources {
            CFRunLoopRemoveSource(mainRunLoop, source, .defaultMode)
        }
        pinRunLoopSources.removeAll()
        pinObservers.removeAll()
        pinTargetCache.removeAll()
        pinWindowCache.removeAll()
        pinWindowSizeCache.removeAll()
        pendingDragCheckPids.removeAll()
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
    }
    
    /// 检查并强制执行固定屏幕规则
    /// T18: 用 AppInfo 列表的"指纹"做短路，未变化时直接跳过 fetch 后逻辑
    /// RT74: 启动期 isPerformingInitialMove=true 时跳过 pinToScreen 路径，避免与
    ///       moveAllOpenAppsToAssignedScreens 竞争 activeDetections
    // 调试计数器——确认 checkAndEnforcePinnedWindows 被调用的频率
    private var checkCallCount: Int = 0

    private func checkAndEnforcePinnedWindows() {
        self.checkCallCount += 1
        let count = self.checkCallCount
        if count <= 5 || count % 30 == 0 {
            logger.debug("checkAndEnforcePinnedWindows: 被调用 #\(count)")
        }

        guard let modelContext = modelContext else {
            logger.error("checkAndEnforcePinnedWindows: modelContext 为 nil")
            return
        }

        if !AXIsProcessTrusted() {
            if hasAccessibilityPermission {
                hasAccessibilityPermission = false
            }
            logger.debug("checkAndEnforcePinnedWindows: 无 AX 权限")
            return
        }
        hasAccessibilityPermission = true

        // R-152: 用 isEnabled == true 谓词只拉启用 App——避免 SwiftData 拉全表后 .filter 的不必要数据传输
        // R-214: FetchDescriptor 加 sortBy: \.bundleIdentifier——保证 fetch 顺序稳定，computeAppsFingerprint 不因顺序漂移而误判
        // 优化：指纹未变时复用 cachedPinnedApps，避免每 100ms 都 SwiftData fetch
        let newFingerprint: Int
        let allApps: [AppInfo]
        // FIX-指纹快速路径失效: 去掉"缓存非空则跳过 fetch"的快速路径——
        // SwiftData 数据可能被 UI 修改（如关闭 pinToScreen），快速路径无法检测到变化，
        // 导致 cachedPinnedApps 永远不刷新，pinObserver 永远不移除。
        // 改为每次都 fetch + 计算指纹，仅在指纹变化时才刷新缓存和 pinObserver
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.bundleIdentifier)]
        )
        guard let fetched = try? modelContext.fetch(descriptor) else {
            logger.error("checkAndEnforcePinnedWindows: SwiftData fetch 失败")
            return
        }
        allApps = fetched
        newFingerprint = computeAppsFingerprint(allApps)

        // 指纹变化时刷新缓存 + pinObserver
        if newFingerprint != lastAppsFingerprint {
            cachedPinnedApps = allApps.filter { $0.isEnabled && $0.pinToScreen }
            lastAppsFingerprint = newFingerprint
            refreshPinObservers()
        }

        let pinnedCount = cachedPinnedApps.count
        logger.debug("checkAndEnforcePinnedWindows: pinToScreen 数量=\(pinnedCount)")

        // RT46: 每次 check 末尾清理无界增长的窗口字典
        trimWindowDictionariesIfNeeded()

        // RT74: 启动期内跳过 pinToScreen 检查，避免与 moveAllOpenAppsToAssignedScreens 竞态
        if isPerformingInitialMove { return }

        // 短路优化：没有任何 App 开启 pinToScreen 时，不需要进入 checkWindowPosition 循环
        if cachedPinnedApps.isEmpty {
            return
        }

        // 获取当前所有屏幕信息
        let currentScreens = getCurrentScreenMappings()

        // FIX-响应慢: 一次性获取所有 running apps，避免循环内多次调用 runningApplications(withBundleIdentifier:)
        let runningApps = NSWorkspace.shared.runningApplications
        var runningAppByBundleID: [String: NSRunningApplication] = [:]
        for app in runningApps {
            if let bid = app.bundleIdentifier {
                runningAppByBundleID[bid] = app
            }
        }

        // FIX-响应慢: 使用缓存的 pinnedApps（已在上方 fetch + filter）
        let pinnedApps = cachedPinnedApps
        if pinnedApps.isEmpty {
            // 无 pinned app 时清理所有 pinObserver
            // FIX: 先收集要移除的 pid，避免遍历中修改字典导致未定义行为
            let pidsToRemove = Array(pinObservers.keys)
            for pid in pidsToRemove {
                removePinObserver(for: pid)
            }
            return
        }

        // FIX-响应慢: 一次性获取所有 on-screen 主窗口，避免每个 App 单独调用 CGWindowListCopyWindowInfo
        let allMainWindows = fetchAllOnScreenMainWindows()

        for appInfo in pinnedApps {
            // RT69: 走 resolveTargetFrame helper
            guard let resolved = resolveTargetFrame(for: appInfo, currentScreens: currentScreens) else { continue }

            // FIX-响应慢: 从预缓存字典查找运行中的应用
            guard let app = runningAppByBundleID[appInfo.bundleIdentifier] else { continue }

            let pid = app.processIdentifier
            let windowID = "\(pid)-main"

            // FIX-拖拽检测: 用户正在拖拽该窗口时跳过检查，避免拖拽中回弹
            // pendingDragCheckPids 记录了正在被拖拽的窗口 pid，等松手后再检查
            if pendingDragCheckPids.contains(pid) { continue }

            // FIX-响应慢: 冷却期内或正在移动中时直接跳过，避免无意义的 AX 调用
            if lastMovedWindows.contains(windowID) || movingWindows.contains(windowID) { continue }

            // 使用预获取的主窗口 bounds（可能为 nil，表示当前无窗口）
            let mainBounds = allMainWindows[pid]
            checkWindowPosition(pid: pid, screenFrame: resolved.frame, targetFrame: resolved.visibleFrame, appBundleID: appInfo.bundleIdentifier, screenID: resolved.id, prebuiltMainBounds: mainBounds)
        }

        // P1: 本轮扫到的存活 pids——previousWindowPositions 中其他 pid 前缀视为死键
        // 补充 didTerminateApplicationNotification 漏掉的边界（App 突然消失/异常退出路径）
        let alivePids: Set<pid_t> = Set(pinnedApps.compactMap {
            runningAppByBundleID[$0.bundleIdentifier]?.processIdentifier
        })
        removeDeadKeys(forAlivePids: alivePids)
    }

    /// P1: 清理 previousWindowPositions / axMetadataCache 中已不存在运行实例的 pid 前缀
    private func removeDeadKeys(forAlivePids alivePids: Set<pid_t>) {
        // 收集死 pid 的前缀（与所有存活 pid 都不匹配）
        let alivePrefixes = alivePids.map { "\($0)-" }
        let deadKeys = previousWindowPositions.keys.filter { key in
            !alivePrefixes.contains(where: { key.hasPrefix($0) })
        }
        if deadKeys.isEmpty { return }
        for key in deadKeys {
            previousWindowPositions.removeValue(forKey: key)
            previousWindowPositionsOrder.removeAll { $0 == key }
            previousWindowPositionsOrderSet.remove(key)
            // axMetadataCache 的 key 是位置，不是 pid 前缀，无法精确清理；
            // 反正 axMetadataCache 的 trim 由 trimWindowDictionariesIfNeeded 兜底
        }
    }

    /// T18: 计算 AppInfo 列表的指纹（用于短路未变化的轮询）
    private func computeAppsFingerprint(_ apps: [AppInfo]) -> Int {
        var hasher = Hasher()
        for app in apps where app.isEnabled {
            hasher.combine(app.bundleIdentifier)
            hasher.combine(app.pinToScreen)
            hasher.combine(app.targetScreenID)
            hasher.combine(app.targetScreenSerialNumber)
            hasher.combine(app.targetScreenName)
        }
        return hasher.finalize()
    }

    // RT46: 字典增长上限——超过 200 条时按插入顺序清理最旧的一半
    private static let windowDictionaryMaxCount = 200
    private func trimWindowDictionariesIfNeeded() {
        if previousWindowPositions.count > Self.windowDictionaryMaxCount {
            let removeCount = Self.windowDictionaryMaxCount / 2
            // RT57: 按并列的插入顺序数组清理，确保删的是最旧的一半
            // R-151: 同步清理配套 Set
            let keysToRemove = Array(previousWindowPositionsOrder.prefix(removeCount))
            for key in keysToRemove {
                previousWindowPositions.removeValue(forKey: key)
                previousWindowPositionsOrderSet.remove(key)
            }
            previousWindowPositionsOrder.removeFirst(removeCount)
            // P2: 改用 Logger——字典清理频率低，改为 logger.debug
            logger.debug("previousWindowPositions 触发清理: 移除 \(removeCount) 条，剩余 \(self.previousWindowPositions.count)")
        }
        // C2: 配套 axMetadataCache 上限——按位置 key 超过 200 时清空一半
        //     位置 key 50px 网格的特性：窗口移动后旧 key 失效，无法精确追踪 LRU
        //     简化处理：直接砍掉前半部分 key
        if axMetadataCache.count > Self.windowDictionaryMaxCount {
            let removeCount = axMetadataCache.count - Self.windowDictionaryMaxCount
            let keys = Array(axMetadataCache.keys.prefix(removeCount))
            for key in keys { axMetadataCache.removeValue(forKey: key) }
        }
        if movingWindows.count > Self.windowDictionaryMaxCount {
            let removeCount = Self.windowDictionaryMaxCount / 2
            let snapshot = Array(movingWindows)
            for id in snapshot.prefix(removeCount) {
                movingWindows.remove(id)
            }
            // P2: 改用 Logger——字典清理频率低
            logger.debug("movingWindows 触发清理: 移除 \(removeCount) 条，剩余 \(self.movingWindows.count)")
        }
        // P2-上限: lastMovedWindows 无显式上限——启动期 moveAllOpenAppsToAssignedScreens
        //     可能一次性插入 N 条，5s 后才由 cooldownWorkItems 清理；加 200 上限兜底
        if lastMovedWindows.count > Self.windowDictionaryMaxCount {
            let removeCount = Self.windowDictionaryMaxCount / 2
            let snapshot = Array(lastMovedWindows)
            for id in snapshot.prefix(removeCount) {
                lastMovedWindows.remove(id)
            }
        }
        // P2-上限: cooldownWorkItems 无显式上限——正常 5s 后自清理，但主线程阻塞时可能累积
        if cooldownWorkItems.count > Self.windowDictionaryMaxCount {
            let removeCount = cooldownWorkItems.count - Self.windowDictionaryMaxCount
            let keys = Array(cooldownWorkItems.keys.prefix(removeCount))
            for key in keys {
                cooldownWorkItems[key]?.cancel()
                cooldownWorkItems.removeValue(forKey: key)
            }
        }
    }
    
    /// 屏幕信息结构（RT54: 与 ScreenManager.ScreenInfo 字段基本一致；保留本地 struct 以避免 isMain 字段强制传递）
    private struct ScreenInfo {
        let id: UInt32
        let name: String
        let frame: CGRect          // screen.frame（全屏区域，含菜单栏/Dock）
        let visibleFrame: CGRect   // screen.visibleFrame（可用区域，排除菜单栏/Dock）
        let serialNumber: String?
    }

    /// 简单的"一次性触发"标记，用于双链并行检测中让先命中的链通知另一链停止
    /// R-213: 标记 Sendable + 方法标 nonisolated，消除 Swift 6 strict concurrency 警告
    private final class AtomicFlag: Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var isSet: Bool { lock.withLock { $0 } }
        /// 尝试设置：仅在未设置时成功，返回是否成功设置
        nonisolated func trySet() -> Bool {
            lock.withLock {
                if $0 { return false }
                $0 = true
                return true
            }
        }
        /// 强制设置（用于主动 cancel 整条检测链）
        nonisolated func set() {
            lock.withLock { $0 = true }
        }
    }

    /// RT1: 单个 App 检测上下文（CG/AX 链 + 稳态校验）
    /// 自身持有 timer；WindowMover 仅在 activeDetections 字典中持有引用
    @MainActor
    private final class DetectionContext {
        let pid: pid_t
        let targetFrame: CGRect
        // 借鉴 yabai rule：窗口标题匹配模式，nil = 匹配所有窗口
        let titlePattern: String?
        // R-213: AtomicFlag 已标 Sendable + 方法 nonisolated，无需 nonisolated(unsafe)
        let stopFlag: AtomicFlag
        // RT103: 记录首次拿到 pid 时的 launchDate；timer 触发时校验，
        //        防止原 App 被 kill 后新 App 复用同一 pid 误命中
        let originalLaunchDate: Date?
        // R-208: nonisolated(unsafe)——DispatchSourceTimer 是 GCD 类型，
        //        cancel() 文档保证线程安全；只在 cancel() 内部访问；
        //        让 cancel() 可以从 deinit（非 MainActor）调用
        nonisolated(unsafe) var cgTimer: DispatchSourceTimer?
        nonisolated(unsafe) var axTimer: DispatchSourceTimer?
        nonisolated(unsafe) var stabilityTimer: DispatchSourceTimer?

        init(pid: pid_t, targetFrame: CGRect, launchDate: Date? = nil, titlePattern: String? = nil) {
            self.pid = pid
            self.targetFrame = targetFrame
            self.titlePattern = titlePattern
            self.stopFlag = AtomicFlag()
            self.originalLaunchDate = launchDate
        }

        // R-208: nonisolated 让 deinit 可以调用——AtomicFlag / DispatchSourceTimer
        //        都是线程安全类型
        nonisolated func cancel() {
            stopFlag.set()
            cgTimer?.cancel(); cgTimer = nil
            axTimer?.cancel(); axTimer = nil
            stabilityTimer?.cancel(); stabilityTimer = nil
        }

        /// RT103: 校验 pid 仍然属于原 App（launchDate 匹配）；不匹配说明 PID 已被复用
        func isPIDStillOriginal() -> Bool {
            // 没有原始 launchDate 记录时（兼容老路径），放宽为只要进程存在即可
            guard let originalLaunchDate = originalLaunchDate else {
                return NSRunningApplication(processIdentifier: pid) != nil
            }
            if let app = NSRunningApplication(processIdentifier: pid) {
                return app.launchDate == originalLaunchDate
            }
            return false
        }
    }
    
    // C3: 屏幕映射缓存 + 屏变化失效
    // 之前：checkAndEnforcePinnedWindows 每 200ms × N 启用 App 都重算
    //       NSScreen.screens 遍历 + 每屏 IOKit serialNumber 调 IOKit
    // 现在：缓存 2s，期间复用；屏变化时 invalidateScreenCache 立即失效
    private var cachedScreenMappings: [ScreenInfo]?
    private var screenCacheValidUntil: Date = .distantPast

    /// 失效屏幕缓存（屏变化时由 observer 调用）
    /// 声明为 nonisolated 允许从 nonisolated 上下文（如 NotificationCenter observer）直接调用
    nonisolated func invalidateScreenCache() {
        Task { @MainActor in
            self.cachedScreenMappings = nil
            self.screenCacheValidUntil = .distantPast
            // FIX-响应慢: 屏幕拓扑变化后 pinTargetCache 中的 frame 可能已失效，需要重建
            self.pinTargetCache.removeAll()
            self.pinWindowCache.removeAll()
            self.pinWindowSizeCache.removeAll()
            self.pendingDragCheckPids.removeAll()
            if let monitor = self.globalMouseUpMonitor {
                NSEvent.removeMonitor(monitor)
                self.globalMouseUpMonitor = nil
            }
            self.refreshPinObservers()
        }
    }

    /// 获取当前屏幕映射（C3: 缓存 2s，命中时直接返回；过期或失效则重算）
    /// RT54 注: ScreenManager 是 @MainActor 实例类，无 shared；本方法保留为本地实现，但与 ScreenManager.screens 字段结构保持一致
    private func getCurrentScreenMappings() -> [ScreenInfo] {
        if let cached = cachedScreenMappings, Date() < screenCacheValidUntil {
            return cached
        }
        var mappings: [ScreenInfo] = []
        for screen in NSScreen.screens {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let name = screen.localizedName
            let frame = screen.frame
            let visibleFrame = screen.visibleFrame
            let serialNumber = ScreenManager.serialNumber(for: screen)
            mappings.append(ScreenInfo(id: screenID, name: name, frame: frame, visibleFrame: visibleFrame, serialNumber: serialNumber))
        }
        cachedScreenMappings = mappings
        screenCacheValidUntil = Date().addingTimeInterval(2.0)  // 2s 兜底过期
        return mappings
    }
    /// 通过序列号查找屏幕
    private func findScreenBySerialNumber(_ serialNumber: String?, currentScreens: [ScreenInfo]) -> ScreenInfo? {
        guard let serial = serialNumber, !serial.isEmpty else { return nil }

        // 只进行精确匹配，避免错误匹配
        if let matched = currentScreens.first(where: { $0.serialNumber == serial }) {
            return matched
        }
        // RT42: 匹配失败时输出 debug 日志
        let candidates = currentScreens.compactMap { $0.serialNumber }.joined(separator: ", ")
        // P2: 改用 Logger——失败时打 debug，避免在 Release 构建中触发字符串构造
        logger.debug("findScreenBySerialNumber 未匹配: 输入=\(serial, privacy: .public) 候选=[\(candidates, privacy: .public)]")
        return nil
    }

    /// 通过名称查找屏幕
    private func findScreenByName(_ name: String, currentScreens: [ScreenInfo]) -> ScreenInfo? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }

        // RT6: 精确匹配 + 标准化匹配（trim + caseInsensitive）
        if let exact = currentScreens.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            return exact
        }
        // R-228: 兼容旧版本——旧版存储的 targetScreenName 可能含分辨率后缀
        //        （如 "DELL U2720Q (2560x1440)"），R-222 后 name 仅 localizedName
        //        与 ScreenManager.screen(name:) 保持一致的兼容逻辑
        for screen in currentScreens {
            let screenName = screen.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !screenName.isEmpty && normalizedName.caseInsensitiveCompare(screenName) != .orderedSame
                && normalizedName.hasPrefix(screenName) {
                let suffix = normalizedName.dropFirst(screenName.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if suffix.hasPrefix("(") || suffix.first?.isNumber == true {
                    return screen
                }
            }
        }
        // RT42: 匹配失败时输出 debug 日志
        let candidates = currentScreens.map { $0.name }.joined(separator: " | ")
        // P2: 改用 Logger——失败时打 debug
        logger.debug("findScreenByName 未匹配: 输入=\(normalizedName, privacy: .public) 候选=[\(candidates, privacy: .public)]")
        return nil
    }

    /// RT69: 抽 resolveTargetFrame helper
    /// 三处调用点（handleAppLaunch / moveAllOpenAppsToAssignedScreens / checkAndEnforcePinnedWindows）统一
    /// 优先级：serialNumber → screenID → screenName
    /// - Returns: (frame, visibleFrame, id) 三元组
    ///   - frame: screen.frame（全屏区域），用于回弹时计算视觉中心
    ///   - visibleFrame: screen.visibleFrame（可用区域），用于判定窗口是否在目标屏 + clamp
    ///   - id: 屏幕ID，仅 checkAndEnforcePinnedWindows 需要
    private func resolveTargetFrame(for appInfo: AppInfo, currentScreens: [ScreenInfo]) -> (frame: CGRect, visibleFrame: CGRect, id: UInt32)? {
        if let serialNumber = appInfo.targetScreenSerialNumber,
           let matched = findScreenBySerialNumber(serialNumber, currentScreens: currentScreens) {
            return (matched.frame, matched.visibleFrame, matched.id)
        }
        if let screenID = appInfo.targetScreenID,
           let screenInfo = getScreenInfo(for: screenID) {
            return (screenInfo.frame, screenInfo.visibleFrame, screenID)
        }
        if let screenName = appInfo.targetScreenName,
           let matched = findScreenByName(screenName, currentScreens: currentScreens) {
            return (matched.frame, matched.visibleFrame, matched.id)
        }
        return nil
    }
    
    /// 检查窗口位置并处理
    /// RT4: 鼠标位置不再作为唯一跳过条件；主判定改为"窗口中心点 OR 50% 面积在目标屏 visibleFrame 内"
    /// C2: 加 AX 元数据缓存——title/role/size 按位置 50px 网格分桶缓存。
    ///     同一窗口静止不动时，title/role/size 不再重复读取，AX 调用从 4 降到 1（仅 kAXPositionAttribute）
    /// FIX-Electron: Electron 应用（如 CherryStudio）的 kAXWindowsAttribute 经常返回空数组或不完整列表，
    ///     导致 pinToScreen 完全失效。改用 CGWindowList 做位置检测（快且对 Electron 可靠），
    ///     只在需要移动时才用 AX 获取具体窗口引用。
    /// FIX-响应慢: 支持传入 prebuiltMainBounds，避免在 checkAndEnforcePinnedWindows 循环内重复调用 CGWindowListCopyWindowInfo
    /// FIX-响应慢: 新增 fastPath 参数——pinObserver 快速路径中直接用 AX 读取位置 + 移动，
    ///     跳过 CGWindowList 扫描，减少 ~50-100ms 延迟
    private func checkWindowPosition(pid: pid_t, screenFrame: CGRect, targetFrame: CGRect, appBundleID: String, screenID: UInt32, prebuiltMainBounds: CGRect? = nil, fastPath: Bool = false) {
        if fastPath {
            // FIX-响应慢: 快速路径——直接用 AX 读取主窗口位置并判断，跳过 CGWindowList
            checkWindowPositionFastPath(pid: pid, screenFrame: screenFrame, targetFrame: targetFrame, screenID: screenID)
            return
        }

        // FIX-响应慢: 优先使用预计算的 bounds；兜底才走单点 CGWindowList 查询（供早期检测路径复用）
        guard let bounds = prebuiltMainBounds ?? findOnScreenWindow(for: pid) else { return }

        // FIX-Electron 步骤 2: 用 CGWindowList 的位置直接判断是否在目标屏
        if isBoundsInTargetFrame(bounds, targetFrame: targetFrame) {
            // 窗口在目标屏——更新位置记录
            let windowID = "\(pid)-main"
            previousWindowPositions[windowID] = bounds.origin
            if !previousWindowPositionsOrderSet.contains(windowID) {
                previousWindowPositionsOrder.append(windowID)
                previousWindowPositionsOrderSet.insert(windowID)
            }
            return
        }

        // FIX-Electron 步骤 3: 窗口不在目标屏——需要 AX 引用来移动
        let windowID = "\(pid)-main"

        // 冷却检查（外层已过滤，保留作为防御）
        if lastMovedWindows.contains(windowID) || movingWindows.contains(windowID) { return }

        // FIX-Electron 步骤 4: 通过 AX 获取窗口引用（只尝试一次，不遍历所有 AX 窗口）
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard axResult == .success, let axWindows = windowsValue as? [AXUIElement] else { return }

        // 找位置最接近 CGWindowList 结果的 AX 窗口
        var bestWindow: AXUIElement? = nil
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for axWindow in axWindows {
            var positionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
                  let posVal = positionValue else { continue }
            var axPosition = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &axPosition)
            let dx = axPosition.x - bounds.origin.x
            let dy = axPosition.y - bounds.origin.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestWindow = axWindow
            }
        }

        guard let targetWindow = bestWindow else { return }

        // FIX-Electron 步骤 5: 执行移动
        movingWindows.insert(windowID)
        // FIX-侧边: 传入 bounds.size 作为 prebuiltSize，避免 AX 读取 size 失败导致居中偏移
        moveWindowToTargetScreen(targetWindow, screenFrame: screenFrame, visibleFrame: targetFrame, windowID: windowID, prebuiltSize: bounds.size)
    }

    /// FIX-响应慢: pinObserver 快速路径——直接用 AX 读取窗口位置 + 移动
    /// 跳过 CGWindowListCopyWindowInfo 全量扫描，减少 ~50-100ms 延迟
    /// 如果 AX 读取失败（如 Electron 应用），回退到 CGWindowList 路径
    /// FIX-响应慢: 缓存主窗口 AXUIElement 引用，避免每次 kAXWindowsAttribute 查询（~5-15ms）
    private func checkWindowPositionFastPath(pid: pid_t, screenFrame: CGRect, targetFrame: CGRect, screenID: UInt32) {
        let windowID = "\(pid)-main"

        // FIX-响应慢: 优先使用缓存的主窗口引用，跳过 kAXWindowsAttribute 查询
        let targetWindow: AXUIElement
        if let cached = pinWindowCache[pid] {
            targetWindow = cached
        } else {
            let appElement = AXUIElementCreateApplication(pid)
            var windowsValue: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

            guard axResult == .success, let axWindows = windowsValue as? [AXUIElement], !axWindows.isEmpty else {
                // AX 失败（如 Electron 应用）——回退到 CGWindowList 路径
                checkWindowPosition(pid: pid, screenFrame: screenFrame, targetFrame: targetFrame, appBundleID: "", screenID: screenID)
                return
            }

            // 找主窗口：优先找 kAXMainAttribute == true 的窗口，否则取第一个
            var mainWindow: AXUIElement? = nil
            for axWindow in axWindows {
                var mainValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXMainAttribute as CFString, &mainValue) == .success,
                   let isMain = mainValue as? Bool, isMain {
                    mainWindow = axWindow
                    break
                }
            }
            targetWindow = mainWindow ?? axWindows[0]
            pinWindowCache[pid] = targetWindow
        }

        // 读取窗口位置
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(targetWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              let posVal = positionValue else {
            // 无法读取位置——缓存可能失效，清除后回退
            pinWindowCache.removeValue(forKey: pid)
            pinWindowSizeCache.removeValue(forKey: pid)
            checkWindowPosition(pid: pid, screenFrame: screenFrame, targetFrame: targetFrame, appBundleID: "", screenID: screenID)
            return
        }
        var position = CGPoint.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &position)

        // FIX-响应慢: size 也缓存，避免每次 kAXSizeAttribute 查询
        var size = CGSize.zero
        if let cachedSize = pinWindowSizeCache[pid] {
            size = cachedSize
        } else {
            var sizeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(targetWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
               let sizeVal = sizeValue {
                AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
                pinWindowSizeCache[pid] = size
            }
        }

        let bounds = CGRect(origin: position, size: size)

        // 判断窗口是否在目标屏
        if isBoundsInTargetFrame(bounds, targetFrame: targetFrame) {
            previousWindowPositions[windowID] = bounds.origin
            if !previousWindowPositionsOrderSet.contains(windowID) {
                previousWindowPositionsOrder.append(windowID)
                previousWindowPositionsOrderSet.insert(windowID)
            }
            return
        }

        // 窗口不在目标屏——冷却检查（与 checkWindowPosition 普通路径一致，在位置判断之后）
        if lastMovedWindows.contains(windowID) || movingWindows.contains(windowID) { return }

        // 直接移动（已有 AX 窗口引用）
        // FIX-侧边: 传入 bounds.size 作为 prebuiltSize，避免 AX 读取 size 失败导致居中偏移
        movingWindows.insert(windowID)
        moveWindowToTargetScreen(targetWindow, screenFrame: screenFrame, visibleFrame: targetFrame, windowID: windowID, prebuiltSize: bounds.size)
    }

    /// 读取 AX 字符串属性辅助方法（用于生成稳定的窗口标识）
    private func copyAXString(_ window: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &value) == .success,
              let str = value as? String else { return nil }
        return str
    }

    /// 读取窗口 size 辅助方法
    private func copySize(_ window: AXUIElement) -> CGSize? {
        var sizeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeVal) == .success,
              let sizeVal = sizeVal else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
    
    /// 获取包含指定点的屏幕
    private func getScreenContainingPoint(_ point: CGPoint) -> CGRect? {
        for screen in NSScreen.screens {
            // 使用 visibleFrame 来匹配 getScreenID 函数中的匹配逻辑
            let screenFrame = screen.visibleFrame
            let relativeX = point.x - screenFrame.origin.x
            let relativeY = point.y - screenFrame.origin.y
            
            if relativeX >= 0 && relativeX < screenFrame.width
               && relativeY >= 0 && relativeY < screenFrame.height {
                return screenFrame
            }
        }
        return nil
    }
    
    /// 获取屏幕ID
    /// R-130: 改用 visibleFrame 容差匹配（与 RT56 isTargetScreenAvailable 一致），
    ///        避免 Dock 高度变化后 getScreenID 返回 nil
    private func getScreenID(_ screenFrame: CGRect) -> UInt32? {
        for screen in NSScreen.screens {
            // R-130: 1.0 像素容差匹配 visibleFrame
            if abs(screen.visibleFrame.minX - screenFrame.minX) < Self.screenFrameTolerance
                && abs(screen.visibleFrame.minY - screenFrame.minY) < Self.screenFrameTolerance
                && abs(screen.visibleFrame.width - screenFrame.width) < Self.screenFrameTolerance
                && abs(screen.visibleFrame.height - screenFrame.height) < Self.screenFrameTolerance {
                return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            }
        }
        return nil
    }
    
    /// FIX-正中: 优先从 AX 读取 size（content 实际尺寸，不含阴影），保证居中计算准确
    ///     CGWindowList bounds.size 在不同 macOS 版本/不同应用上可能包含窗口阴影，
    ///     用 AX size 才能保证 content 在 visibleFrame 几何中心。
    ///     仅当 AX size 读取失败（width<=0 或 height<=0）时回退到 fallback（通常是 CG bounds.size）
    private func readWindowSizeFromAX(_ window: AXUIElement, fallback: CGSize? = nil) -> CGSize {
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeVal = sizeValue {
            var size = CGSize.zero
            // Swift 6 SDK: AXValueGetValue 需要 3 个参数 (value, type, outValue)
            if AXValueGetValue(sizeVal as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 {
                return size
            }
        }
        return fallback ?? .zero
    }

    /// FIX-自由移动: 将窗口移入目标屏幕
    ///     行为：窗口在目标屏内时保持不动；窗口被拖到其他屏幕时，居中弹回目标屏幕。
    /// FIX-正中5: 回弹时使用 hideMoveUnhide（与启动期一致），而非直接 AX 设置位置。
    ///     直接 AX 设置会被 macOS 窗口管理器"纠正"（吸附/避免遮挡），导致窗口不在正中。
    ///     hideMoveUnhide 先隐藏窗口再移动，窗口管理器不会干扰隐藏窗口的位置设置。
    private func moveWindowToTargetScreen(_ window: AXUIElement, screenFrame: CGRect, visibleFrame: CGRect, windowID: String, prebuiltSize: CGSize? = nil) {
        // FIX-正中5: 使用 hideMoveUnhide 替代直接 AX 设置
        //     启动期用 hideMoveUnhide 能正确居中，回弹期也应一致
        hideMoveUnhide(axWindows: [window], targetFrame: visibleFrame)

        lastMovedWindows.insert(windowID)

        // FIX-正中5: 回读窗口实际位置作为缓存（hideMoveUnhide 内部有 clamp，实际位置可能与理论计算不同）
        let actualSize = readWindowSizeFromAX(window, fallback: prebuiltSize)
        let expectedPos = CGPoint(
            x: visibleFrame.midX - actualSize.width / 2,
            y: visibleFrame.midY - actualSize.height / 2
        )
        // 尝试回读 AX 实际位置，失败时用计算值
        var actualPos = expectedPos
        var posValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
           let posVal = posValue {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &actualPos)
        }
        previousWindowPositions[windowID] = actualPos
        if !previousWindowPositionsOrderSet.contains(windowID) {
            previousWindowPositionsOrder.append(windowID)
            previousWindowPositionsOrderSet.insert(windowID)
        }

        // FIX-正中5: 延迟验证——500ms 后读取实际位置，如果偏离中心则再次 hideMoveUnhide
        let windowRef = window
        let windowIDCopy = windowID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.verifyAndRecenterWindow(window: windowRef, visibleFrame: visibleFrame, windowID: windowIDCopy)
        }

        // FIX-响应慢: 冷却期从 2s 缩短到 1s，提升连续拖动场景响应
        let key = cooldownKey(windowID: windowID)
        cooldownWorkItems[key]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.lastMovedWindows.remove(windowID)
            self?.cooldownWorkItems.removeValue(forKey: key)
        }
        cooldownWorkItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)

        movingWindows.remove(windowID)
    }

    /// FIX-正中5: 验证窗口是否在 visibleFrame 正中，如果偏离则用 hideMoveUnhide 重新居中
    private func verifyAndRecenterWindow(window: AXUIElement, visibleFrame: CGRect, windowID: String) {
        var currentPos = CGPoint.zero
        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              let posVal = posValue else { return }
        AXValueGetValue(posVal as! AXValue, .cgPoint, &currentPos)

        let useSize = readWindowSizeFromAX(window)
        guard useSize.width > 0, useSize.height > 0 else { return }

        let visibleCenterX = visibleFrame.midX
        let visibleCenterY = visibleFrame.midY
        let currentCenterX = currentPos.x + useSize.width / 2
        let currentCenterY = currentPos.y + useSize.height / 2
        let isOffCenter = abs(currentCenterX - visibleCenterX) > 5 || abs(currentCenterY - visibleCenterY) > 5

        if isOffCenter {
            logger.debug("verifyAndRecenterWindow: windowID=\(windowID, privacy: .public) currentCenter=\(NSStringFromPoint(CGPoint(x: currentCenterX, y: currentCenterY)), privacy: .public) visibleCenter=\(NSStringFromPoint(CGPoint(x: visibleCenterX, y: visibleCenterY)), privacy: .public) useSize=\(NSStringFromSize(useSize), privacy: .public) → recentering")
            hideMoveUnhide(axWindows: [window], targetFrame: visibleFrame)
        }
    }
    
    private func getScreenInfo(for displayID: UInt32) -> (frame: CGRect, visibleFrame: CGRect)? {
        for screen in NSScreen.screens {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if screenID == displayID {
                return (screen.frame, screen.visibleFrame)
            }
        }
        return nil
    }
    
    func moveAppToScreen(bundleIdentifier: String, screenID: UInt32, screenSerialNumber: String?, titlePattern: String? = nil) {
        // 首先尝试通过序列号找到屏幕
        if let serial = screenSerialNumber {
            if let matchedScreen = findScreenBySerialNumber(serial, currentScreens: getCurrentScreenMappings()) {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                    let pid = app.processIdentifier
                    // RT67: 走 earlyWindowCatcher 链路（hide → move → unhide + 稳态校验 + 防回弹）
                    // 启动期使用 visibleFrame 居中放置，避免覆盖菜单栏/Dock
                    earlyWindowCatcher(pid: pid, targetFrame: matchedScreen.visibleFrame, titlePattern: titlePattern)
                }
                return
            }
        }

        // 备用：通过 ID 找屏幕
        guard let screenInfo = getScreenInfo(for: screenID) else { return }

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            let pid = app.processIdentifier
            // RT67: 同上
            earlyWindowCatcher(pid: pid, targetFrame: screenInfo.visibleFrame, titlePattern: titlePattern)
        }
    }

    /// 移动窗口到指定位置（居中）
    private func moveWindowToFrameImmediate(_ window: AXUIElement, targetFrame: CGRect) {
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        
        var size = CGSize.zero
        if let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }
        
        var newPosition = CGPoint(
            x: targetFrame.origin.x + (targetFrame.width - size.width) / 2,
            y: targetFrame.origin.y + (targetFrame.height - size.height) / 2
        )

        // FIX-居中偏移: clamp 确保窗口完全在 targetFrame 内
        if size.width > targetFrame.width {
            newPosition.x = targetFrame.origin.x
        } else {
            newPosition.x = max(targetFrame.origin.x, min(newPosition.x, targetFrame.maxX - size.width))
        }
        if size.height > targetFrame.height {
            newPosition.y = targetFrame.origin.y
        } else {
            newPosition.y = max(targetFrame.origin.y, min(newPosition.y, targetFrame.maxY - size.height))
        }

        var position = newPosition
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
    }
    
    func checkAccessibilityPermission() -> Bool {
        // 先检查是否已有权限（不显示提示）
        hasAccessibilityPermission = AXIsProcessTrusted()
        return hasAccessibilityPermission
    }
    
    func requestAccessibilityPermission() {
        // 注意：macOS 的辅助功能权限基于代码签名。
        // 如果应用签名变化（如版本更新后使用不同签名），权限会失效，需要重新授权。
        // GitHub Action 发布的应用使用临时签名，每次发布签名可能不同。
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    /// 立即触发窗口位置检查
    func triggerImmediateCheck() {
        // 强制失效缓存，确保下次 check 重新 fetch
        lastAppsFingerprint = 0
        cachedPinnedApps = []
        checkAndEnforcePinnedWindows()
    }
}
