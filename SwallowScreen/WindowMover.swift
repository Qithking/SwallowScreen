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
import os
// SPM 构建下 ScreenGeometry 位于 SwallowScreenCore 模块；Xcode 工程为平面 target 无需 import
#if canImport(SwallowScreenCore)
import SwallowScreenCore
#endif

@MainActor
class WindowMover: ObservableObject {
    // C 回调需要直接访问实例，不走 NotificationCenter 桥接
    static weak var shared: WindowMover?

    @Published var isMonitoring: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    
    private var timer: DispatchSourceTimer?
    private var modelContext: ModelContext?
    private var checkInterval: TimeInterval = 0.1  // 固定屏幕检查间隔（100ms，平衡响应速度与 CPU）

    // 统一 Logger——debug 级别日志不构造消息字符串
    private let logger = Logger(subsystem: "com.swallowscreen.SwallowScreen", category: "WindowMover")
    private var previousWindowPositions: [String: CGPoint] = [:]
    // 维护插入顺序数组，按索引清理最旧的一半
    private var previousWindowPositionsOrder: [String] = []
    // 辅助 Set，contains O(1) 避免数组 O(n) 扫描
    private var previousWindowPositionsOrderSet: Set<String> = []
    // 冷却与守卫状态存于 CooldownRegistry——key 约定见其头注释；
    // 该类型为 nonisolated + @unchecked Sendable（NSLock 保护全部状态），
    // 无需 nonisolated(unsafe)，Sendable let 在 deinit 中也可直接访问
    private let cooldowns = CooldownRegistry()
    // AX 元数据缓存（title/role/size），按位置 50px 网格分桶——窗口静止时复用，AX 调用 ↓ ~75%
    // previousWindowPositions 管"位置是否变化"，本缓存管"title/role/size 是否需重读"
    private var axMetadataCache: [String: (title: String, role: String, size: CGSize?)] = [:]

    // 观察者 token，用于 deinit 时清理
    private var appLaunchObserverToken: NSObjectProtocol?
    // 屏变化观察者 token：屏变化时清理 pin 侧缓存并刷新 observers
    private var screenChangeObserverToken: NSObjectProtocol?
    // App 终止观察者 token：App 退出时清理其相关字典键
    private var appTerminationObserverToken: NSObjectProtocol?
    // 监听 Space 切换，触发即时 pinToScreen 检查
    private var spaceChangeObserverToken: NSObjectProtocol?
    // AppInfo 列表指纹，用于"配置未变则跳过"
    private var lastAppsFingerprint: Int = 0
    // 缓存 pinned AppInfo 列表——指纹未变时复用，避免每 100ms 都 SwiftData fetch
    private var cachedPinnedApps: [AppInfo] = []
    // 按 pid 维度持有的检测上下文；新启动同 pid App 会取消旧上下文
    private var activeDetections: [pid_t: DetectionContext] = [:]
    // 稳态校验每个 pid 独立计数
    private var stabilityCount: [pid_t: Int] = [:]
    // CG 检测间隔：30Hz (33ms) 足够"窗口首帧出现"检测；CPU 占用预期 ↓ 50-70%
    private var cgDetectionInterval: TimeInterval {
        // 简化：固定 33ms（30Hz）。若要保留"前快后慢"，加 elapsedSinceStart 即可
        return 0.033
    }
    // 启动期 moveAllOpenAppsToAssignedScreens 的 task 句柄，可取消
    private var moveAllAppsTask: Task<Void, Never>?
    // 启动期 true，期间 checkAndEnforcePinnedWindows 跳过 pinToScreen
    private var isPerformingInitialMove: Bool = false
    // AX 兜底滑动探测链的 per-pid 生成 ID——stopMonitoring 清除后，已入队 tick
    // 通过 ID 校验自停止，避免 stop→start 快速切换时旧链误探测同 pid 新会话
    private var axFallbackProbeIDs: [pid_t: UUID] = [:]

    // AXObserver 事件驱动主路径：按 pid 持有实例，窗口创建通知到达即搬动，无需轮询
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
    // created 快照截止时间：订阅 kAXWindowCreatedNotification 后，部分应用会立即为已存在窗口
    // 补发 created 通知（AX 快照），此时搬动会与启动期 startStabilityCheck 冲突，
    // 窗口停在错误屏幕且无人纠正。订阅后 1s 内忽略全部 created 通知。
    private var createdSnapshotCutoff: [pid_t: Date] = [:]

    // pinObserver 快速路径缓存——pid → (targetFrame, screenID)
    // 窗口移动事件到达时直接查缓存，跳过 SwiftData fetch + runningApplications 遍历
    // 在 refreshPinObservers / handleScreenConfigurationChanged 时同步更新
    private var pinTargetCache: [pid_t: (frame: CGRect, visibleFrame: CGRect, screenID: UInt32)] = [:]

    // 缓存 pid → 主窗口 AXUIElement 引用，避免每次 kAXWindowsAttribute 查询（~5-15ms）
    private var pinWindowCache: [pid_t: AXUIElement] = [:]
    // 缓存 pid → 窗口尺寸，避免每次 kAXSizeAttribute 查询（~3-5ms）
    // 附带缓存时间戳：窗口 resize 后陈旧尺寸会导致 isBoundsInTargetFrame
    // 中心点误判与搬动 prebuiltSize 错误，超过 TTL 强制重读刷新
    private var pinWindowSizeCache: [pid_t: (size: CGSize, cachedAt: Date)] = [:]
    /// pinWindowSizeCache 过期时长
    private static let pinWindowSizeCacheTTL: TimeInterval = 5.0

    // 拖拽检测：拖拽中通过 isMouseLeftButtonDown() 检测鼠标状态，
    // 鼠标按下时记录 pid，等全局 leftMouseUp 事件触发后立即回弹
    private var pendingDragCheckPids: Set<pid_t> = []
    private var globalMouseUpMonitor: Any? = nil
    // 屏幕信息/目标屏解析统一走 ScreenManager
    private let screenManager: ScreenManager

    init(screenManager: ScreenManager) {
        self.screenManager = screenManager
        _ = checkAccessibilityPermission()
        // NSWorkspace.didLaunchApplicationNotification 监听在 startMonitoring 中注册，
        // 避免 AppDelegate 延迟 1s 创建 WindowMover 期间丢失应用启动通知
        setupAppTerminationObserver()
        setupScreenChangeObserver()
        setupAXWindowCreatedObserver()
        setupSpaceChangeObserver()
        Self.shared = self
    }

    deinit {
        // deinit 是 nonisolated，不能直接修改 @MainActor 属性
        // 但 Self.shared 是 weak var，ARC 释放时会自动置 nil，无需手动清理
        // 显式 cancel 顶层 dispatch timer；之前漏 cancel 导致 ARC 释放时
        // dispatch source 仍持引用直到 timer 触发或手动 cancel
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
        // deinit 可能在非主线程执行，CFRunLoopGetCurrent() 返回错误的 RunLoop
        // source 是加在主 RunLoop 上的，必须从主 RunLoop 移除
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
        cooldowns.cancelAll()
    }

    /// 监听 .screenConfigurationChanged 屏变化事件——重建 pin 侧缓存并刷新 observers
    /// （屏幕列表缓存已删除，ScreenManager 自行维护 screens 刷新）
    private func setupScreenChangeObserver() {
        screenChangeObserverToken = NotificationCenter.default.addObserver(
            forName: .screenConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.handleScreenConfigurationChanged()
        }
    }

    // MARK: - AXObserver 事件驱动检测

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

    /// 监听 Space 切换通知：切换后新 Space 上的 pinned 窗口可能位置不对
    /// （用户从其他 Space 拖过来），立即检查并纠正
    /// NSWorkspaceActiveSpaceDidChangeNotification 在切换完成时触发
    private func setupSpaceChangeObserver() {
        spaceChangeObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // 延迟 50ms 等 Space 切换动画完成，避免 AX API 在动画期间返回旧位置
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.checkAndEnforcePinnedWindows()
            }
        }
    }

    /// 为指定 pid 创建 AXObserver，订阅 kAXWindowCreatedNotification（事件驱动，窗口创建即触发搬动）
    private func setupAXObserver(for pid: pid_t, targetFrame: CGRect, titlePattern: String? = nil) {
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
        // 显式使用 CFRunLoopGetMain()，与 removeAXObserver/deinit 中移除保持一致
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        axObservers[pid] = observer
        axRunLoopSources[pid] = runLoopSource
        // 注册成功即启动空闲超时——永不匹配时最终清理 observer
        scheduleAXObserverTimeout(for: pid)
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
    private func handleAXWindowCreated(pid: pid_t, element: AXUIElement) {
        guard let observation = pendingAXObservations[pid] else {
            // 无待处理观察（可能已被清理）
            return
        }
        let targetFrame = observation.targetFrame
        let titlePattern = observation.titlePattern

        logger.debug("AXObserver 检测到新窗口: pid=\(pid)")

        // 按标题过滤窗口
        let matchedWindows = filterWindowsByTitle([element], pattern: titlePattern)
        guard !matchedWindows.isEmpty else {
            logger.debug("AXObserver 窗口标题不匹配 pattern: pid=\(pid) pattern=\(titlePattern ?? "<nil>", privacy: .public)")
            // 标题不匹配时不取消 observer，等待后续窗口创建
            // 刷新空闲超时——最后一次事件后 15s 仍无匹配则清理 observer
            scheduleAXObserverTimeout(for: pid)
            return
        }

        // 停兜底轮询 timer 但保留 context——0.12s 后 startStabilityCheck 需要
        // originalLaunchDate 做 PID 复用防御
        stopDetectionTimers(pid: pid)

        hideMoveUnhide(axWindows: matchedWindows, targetFrame: targetFrame)

        // 启动稳态校验
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
        }

        // 清理 observer（窗口创建通知只需一次）
        removeAXObserver(for: pid)
        pendingAXObservations.removeValue(forKey: pid)
        // 已命中，取消空闲超时
        cancelAXObserverTimeout(for: pid)
    }

    /// 移除指定 pid 的 AXObserver + RunLoopSource
    private func removeAXObserver(for pid: pid_t) {
        if let source = axRunLoopSources[pid] {
            // 使用 CFRunLoopGetMain() 而非 CFRunLoopGetCurrent()，
            // source 加在主 RunLoop 上，必须从主 RunLoop 移除
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            axRunLoopSources.removeValue(forKey: pid)
        }
        if let observer = axObservers[pid] {
            let appElement = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(observer, appElement, kAXWindowCreatedNotification as CFString)
            axObservers.removeValue(forKey: pid)
        }
    }

    /// 观察者空闲超时——标题配不上 / 永不匹配时清理 observer，避免永久挂起
    private static let axObserverIdleTimeout: TimeInterval = 15.0

    /// 调度（或刷新）观察者空闲超时计时
    private func scheduleAXObserverTimeout(for pid: pid_t) {
        cooldowns.coolDown("axTimeout:\(pid)", duration: Self.axObserverIdleTimeout) { [weak self] in
            guard let self = self else { return }
            // observation 已不存在 = 已命中清理或 App 已退出，无需处理
            guard self.pendingAXObservations[pid] != nil else { return }
            self.logger.info("AXObserver 空闲超时，清理观察者: pid=\(pid, privacy: .public)")
            self.removeAXObserver(for: pid)
            self.pendingAXObservations.removeValue(forKey: pid)
        }
    }

    /// 取消观察者空闲超时计时（observer 正常命中移除时调用）
    private func cancelAXObserverTimeout(for pid: pid_t) {
        cooldowns.cancel("axTimeout:\(pid)")
    }

    // MARK: - pinToScreen 窗口移动事件驱动
    // C 回调直接 DispatchQueue.main.async 调用

    /// 为 pinned app 创建 AXObserver，订阅 kAXMovedNotification + kAXWindowCreatedNotification
    /// moved 立即触发检查（<10ms）；created 覆盖轮询管不到的新窗口（轮询每 pid 只查最大主窗口）
    private func setupPinObserver(for pid: pid_t) {
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

        // 订阅窗口创建通知；失败不影响 moved 监听（部分应用可能不支持）
        let createdResult = AXObserverAddNotification(
            observer, appElement,
            kAXWindowCreatedNotification as CFString,
            nil
        )
        if createdResult == .success {
            // 订阅成功即进入快照截止窗口——应用会为所有已存在窗口
            // 补发 created 通知（AX 快照），窗口期内忽略，避免与启动搬动链路冲突
            createdSnapshotCutoff[pid] = Date().addingTimeInterval(1.0)
        } else {
            logger.debug("pinObserver kAXWindowCreatedNotification 订阅失败: pid=\(pid) result=\(createdResult.rawValue)")
        }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        // 显式使用 CFRunLoopGetMain()，与 removePinObserver/deinit 中移除保持一致
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        pinObservers[pid] = observer
        pinRunLoopSources[pid] = runLoopSource
        logger.debug("pinObserver 已创建: pid=\(pid)")
    }

    /// pinToScreen AXObserver C 回调——窗口移动/创建通知
    /// 直接 DispatchQueue.main.async 调用，不走 NotificationCenter 桥接（省 ~10-20ms）
    /// 按通知类型分发：moved 走拖拽检测回弹，created 携带窗口 element 立即搬新窗口
    private static let pinObserverCallback: AXObserverCallback = { observer, element, notification, _ in
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        guard pidResult == .success else { return }

        let notificationStr = notification as String
        DispatchQueue.main.async {
            if notificationStr == kAXMovedNotification as String {
                WindowMover.shared?.handlePinWindowMoved(pid: pid)
            } else if notificationStr == kAXWindowCreatedNotification as String {
                WindowMover.shared?.handlePinWindowCreated(pid: pid, element: element)
            }
        }
    }

    /// 窗口移动事件到达——通过鼠标左键状态判断是否拖拽：
    /// 按下 = 拖拽中，记 pid 等松手再检查；松开 = 立即检查回弹
    /// 松手检测用 NSEvent.addGlobalMonitorForEvents(.leftMouseUp)，比轮询可靠
    private func handlePinWindowMoved(pid: pid_t) {
        guard !isPerformingInitialMove else { return }

        let windowID = "\(pid)-main"
        guard !cooldowns.isCoolingDown("moving:\(windowID)") else { return }

        let isDragging = isMouseLeftButtonDown()

        if isDragging {
            // 拖拽中：记 pid，松手后再检查
            pendingDragCheckPids.insert(pid)
            startGlobalMouseUpMonitor()
        } else {
            // 已松开——不是用户拖拽（可能是系统移动窗口），立即检查回弹
            performPinCheck(pid: pid)
        }
    }

    /// pinned app 新窗口创建——立即搬到固定屏幕
    /// 背景：100ms 轮询每 pid 只查最大主窗口，小窗口创建后不会被搬，直到用户手动拖一次
    private func handlePinWindowCreated(pid: pid_t, element: AXUIElement) {
        // 启动期跳过——启动窗口由 handleAppLaunch / earlyWindowCatcher 负责
        guard !isPerformingInitialMove else { return }

        // 快照截止窗口内忽略——订阅 created 后应用会为所有已存在窗口
        // 补发快照通知，此时搬动会与启动稳定性校验冲突，窗口停在错误屏幕
        if let cutoff = createdSnapshotCutoff[pid] {
            if Date() < cutoff { return }
            // 截止已过，清掉记录，后续 created 通知按新窗口处理
            createdSnapshotCutoff.removeValue(forKey: pid)
        }

        // 仅处理 pinned app（缓存未命中说明已取消固定或非 pinned）
        guard let cached = pinTargetCache[pid] else { return }

        // 读取新窗口位置 + 尺寸（可读 = 窗口存活且就绪）
        guard let position = AXWindowReader.position(element),
              let size = AXWindowReader.size(element) else { return }

        // 过滤瞬时/辅助窗口（与 CGWindowList 路径的 ≥50 尺寸过滤一致）
        guard size.width >= 50, size.height >= 50 else { return }

        let bounds = CGRect(origin: position, size: size)
        guard !isBoundsInTargetFrame(bounds, targetFrame: cached.visibleFrame) else { return }

        // 该窗口标识正在搬动/冷却中则跳过（独立于主窗口的 "\(pid)-main" key）
        let windowID = "\(pid)-created"
        guard !cooldowns.isCoolingDown("moving:\(windowID)"),
              !cooldowns.isCoolingDown("move:\(windowID)") else { return }

        cooldowns.hold("moving:\(windowID)")
        moveWindowToTargetScreen(element, screenFrame: cached.frame, visibleFrame: cached.visibleFrame, windowID: windowID, prebuiltSize: size)
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
    /// 松手后如果 pendingDragCheckPids 仍非空（多窗口拖拽场景），重新启动 monitor
    private func handleGlobalMouseUp() {
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }

        let pidsToCheck = pendingDragCheckPids
        pendingDragCheckPids.removeAll()

        for pid in pidsToCheck {
            performPinCheck(pid: pid)
        }

        // 如果在检查过程中又有新的拖拽 move 事件（pendingDragCheckPids 重新非空），
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
        guard !cooldowns.isCoolingDown("move:\(windowID)") else { return }

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

        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.processIdentifier == pid }),
              let bundleID = app.bundleIdentifier else { return }

        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true && $0.pinToScreen == true && $0.bundleIdentifier == bundleID }
        )
        guard let appInfo = try? modelContext.fetch(descriptor).first else { return }

        // 目标屏解析统一走 ScreenManager.resolveTarget
        guard let resolved = screenManager.resolveTarget(for: appInfo) else { return }

        // 只查单个 pid 的窗口，不扫描全部
        checkWindowPosition(pid: pid, screenFrame: resolved.frame, targetFrame: resolved.visibleFrame, appBundleID: appInfo.bundleIdentifier, screenID: resolved.id)
    }

    /// 移除指定 pid 的 pinToScreen observer
    private func removePinObserver(for pid: pid_t) {
        if let source = pinRunLoopSources[pid] {
            // 使用 CFRunLoopGetMain() 而非 CFRunLoopGetCurrent()，
            // source 加在主 RunLoop 上，必须从主 RunLoop 移除
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            pinRunLoopSources.removeValue(forKey: pid)
        }
        if let observer = pinObservers[pid] {
            let appElement = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(observer, appElement, kAXMovedNotification as CFString)
            // created 通知与 moved 注册在同一 observer，移除时同步清理
            AXObserverRemoveNotification(observer, appElement, kAXWindowCreatedNotification as CFString)
            pinObservers.removeValue(forKey: pid)
        }
        pinTargetCache.removeValue(forKey: pid)
        pinWindowCache.removeValue(forKey: pid)
        pinWindowSizeCache.removeValue(forKey: pid)
        // 清理 created 快照截止记录，避免残留误吞新窗口通知
        createdSnapshotCutoff.removeValue(forKey: pid)
        // 清理退出全屏冷却记录，避免同 pid 新实例继承过期时间戳
        cooldowns.cancel("fsExit:\(pid)")
        pendingDragCheckPids.remove(pid)
        // 拖拽窗口清空后移除全局监听
        if pendingDragCheckPids.isEmpty, let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseUpMonitor = nil
        }
    }

    /// 刷新所有 pinned app 的 pinObserver（配置变更时调用）
    /// 新增 pinToScreen → 建 observer；取消 → 移除 observer；同时重建 pinTargetCache
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

        var desiredPids: Set<pid_t> = []
        var newPinTargetCache: [pid_t: (frame: CGRect, visibleFrame: CGRect, screenID: UInt32)] = [:]
        for appInfo in pinnedApps {
            if runningBundleIDs.contains(appInfo.bundleIdentifier),
               let pid = bundleIDToPid[appInfo.bundleIdentifier] {
                desiredPids.insert(pid)
                setupPinObserver(for: pid)
                // 预计算 targetFrame 并缓存（统一走 ScreenManager.resolveTarget）
                if let resolved = screenManager.resolveTarget(for: appInfo) {
                    newPinTargetCache[pid] = (resolved.frame, resolved.visibleFrame, resolved.id)
                }
            }
        }
        pinTargetCache = newPinTargetCache

        // 收集要移除的 pid，避免遍历中修改字典导致未定义行为
        let pidsToRemove = pinObservers.keys.filter { !desiredPids.contains($0) }
        for pid in pidsToRemove {
            removePinObserver(for: pid)
        }
    }

    /// 监听 App 退出事件——及时清理该 App 的字典残留键
    /// 通过 didTerminateApplicationNotification 立即清理所有与该 pid 相关的状态，
    /// 避免 timer tick 间隙 App 退出且 tick 被 cancel 时 context 残留与死键
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
            if let context = self.activeDetections.removeValue(forKey: pid) {
                context.cancel()
            }
            self.stabilityCount.removeValue(forKey: pid)
            self.removeAXObserver(for: pid)
            self.pendingAXObservations.removeValue(forKey: pid)
            self.cancelAXObserverTimeout(for: pid)
            self.removePinObserver(for: pid)
            // 删除该 pid 前缀的所有 windowID 键
            let pidPrefix = "\(pid)-"
            // 先收集要删除的 key，避免遍历中修改字典导致未定义行为
            let posKeysToRemove = self.previousWindowPositions.keys.filter { $0.hasPrefix(pidPrefix) }
            for key in posKeysToRemove {
                self.previousWindowPositions.removeValue(forKey: key)
                self.previousWindowPositionsOrder.removeAll { $0 == key }
                self.previousWindowPositionsOrderSet.remove(key)
            }
            // moving/move/unhide 冷却键按 pid 前缀清理：
            // "move:"/"moving:" 键带命名空间前缀，需显式匹配，裸 pidPrefix 兜底；
            // unhide: 按窗口指针命名，不参与 pid 清理
            self.cooldowns.removeKeys { key in
                key.hasPrefix("move:\(pidPrefix)") || key.hasPrefix("moving:\(pidPrefix)") || key.hasPrefix(pidPrefix)
            }
        }
    }
    
    /// 设置应用启动观察者
    /// token 已存在则跳过，配合 startMonitoring 调用
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
            // 内层 Task 也加 [weak self] 捕获——Swift 6 strict concurrency
            // 下，inner Task 默认隐式捕获 outer closure 的 weak self 会触发
            // `Reference to captured var 'self' in concurrently-executing code`
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleAppLaunch(bundleIdentifier: bundleID, pid: pid)
            }
        }
    }
    
    /// 处理应用启动
    /// isEnabled/bundleID 均为非 optional，可在 SQLite 层过滤；hasTarget 含 targetScreenName
    private func handleAppLaunch(bundleIdentifier: String, pid: pid_t) {
        guard let modelContext = modelContext else { return }

        // 组合谓词：isEnabled + bundleIdentifier 同时满足
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true && $0.bundleIdentifier == bundleIdentifier }
        )
        guard let appInfo = try? modelContext.fetch(descriptor).first else { return }

        // pinToScreen 与 targetScreen 共享同一启动搬动入口
        // hasTarget 包含 targetScreenName——只设 name 的 App 也能被 handleAppLaunch 捕获
        let hasTarget = appInfo.targetScreenID != nil
            || appInfo.targetScreenSerialNumber != nil
            || appInfo.targetScreenName != nil
        guard appInfo.pinToScreen || hasTarget else { return }

        // 目标屏解析统一走 ScreenManager.resolveTarget
        guard let resolved = screenManager.resolveTarget(for: appInfo) else {
            // 屏幕配置匹配失败时输出日志，便于定位"配置屏幕已拔掉"
            logger.error("未找到 App 配置的目标屏幕: bundleID=\(bundleIdentifier, privacy: .public) targetScreenID=\(String(describing: appInfo.targetScreenID), privacy: .public) targetScreenSerialNumber=\(appInfo.targetScreenSerialNumber ?? "<nil>", privacy: .public) targetScreenName=\(appInfo.targetScreenName ?? "<nil>", privacy: .public)")
            return
        }

        logger.info("handleAppLaunch 解析目标屏幕: bundleID=\(bundleIdentifier, privacy: .public) screenID=\(resolved.id) frame=\(NSStringFromRect(resolved.frame), privacy: .public) visibleFrame=\(NSStringFromRect(resolved.visibleFrame), privacy: .public)")

        // AXObserver 事件驱动为主路径（零轮询）；轮询降级为兜底——AXObserver 对 Electron 等少数 App 不触发
        setupAXObserver(for: pid, targetFrame: resolved.visibleFrame, titlePattern: appInfo.windowTitlePattern)

        // 兜底双链轮询（CG 33ms + AX 100ms）；AXObserver 先命中时自动取消
        earlyWindowCatcher(pid: pid, targetFrame: resolved.visibleFrame, titlePattern: appInfo.windowTitlePattern)

        // 延迟 AX 兜底：部分 App（如微信）启动时 AXObserver/CGWindowList 都检测不到窗口，
        // 但几百 ms 后 AX 窗口属性可用。滑动探测每 40ms 读一次 AX 窗口，就绪立即搬窗
        scheduleAXFallbackMove(pid: pid, targetFrame: resolved.visibleFrame,
                               launchDate: NSRunningApplication(processIdentifier: pid)?.launchDate)
    }

    /// 应用启动后的延迟 AX 兜底搬窗：每 40ms 读一次 AX 窗口，出现即搬（微信类 App
    /// 可见期缩短至"AX 就绪 + ≤40ms"）。停止：命中搬动 / 1.5s 超时 / stopMonitoring。
    /// 记录调度时 launchDate，探测时校验 PID 未被复用，防旧 App 退出后新 App 误中旧 targetFrame
    private func scheduleAXFallbackMove(pid: pid_t, targetFrame: CGRect, launchDate: Date? = nil) {
        let startedAt = Date()
        let timeout: TimeInterval = 1.5
        // 生成链 ID：stopMonitoring 清除 axFallbackProbeIDs 后，已入队 tick 校验失败自停止
        let probeID = UUID()
        axFallbackProbeIDs[pid] = probeID
        // 首次立即探测（普通 App 窗口已出现则 t≈0 命中）；未出现则 40ms 间隔递归
        probeAXFallbackTick(pid: pid, targetFrame: targetFrame, launchDate: launchDate, startedAt: startedAt, timeout: timeout, probeID: probeID)
    }

    /// 滑动探测单次 tick——窗口就绪即搬动；未就绪则 40ms 后继续，命中/超时/停止 三条件自停止
    private func probeAXFallbackTick(pid: pid_t, targetFrame: CGRect, launchDate: Date?, startedAt: Date, timeout: TimeInterval, probeID: UUID) {
        guard isMonitoring else { return }
        // 链 ID 校验：stopMonitoring 后该 pid 的链已失效（stop→start 新会话有新 ID）
        guard axFallbackProbeIDs[pid] == probeID else { return }
        guard Date().timeIntervalSince(startedAt) < timeout else {
            // 超时自停止——清理链 ID 避免残留
            axFallbackProbeIDs.removeValue(forKey: pid)
            return
        }
        // PID 复用防御——进程必须存在且 launchDate 与调度时刻一致
        guard let currentApp = NSRunningApplication(processIdentifier: pid) else { return }
        if let launchDate = launchDate, currentApp.launchDate != launchDate {
            logger.info("AX 兜底: PID 已被复用，跳过搬窗 pid=\(pid, privacy: .public)")
            return
        }
        guard let axWindows = AXWindowReader.windows(pid: pid), !axWindows.isEmpty,
              let mainWindow = pickMainWindow(from: axWindows),
              let currentBounds = AXWindowReader.bounds(mainWindow) else {
            // 窗口未就绪（微信类 AX 树未建）——40ms 后继续探测
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self = self else { return }
                self.probeAXFallbackTick(pid: pid, targetFrame: targetFrame, launchDate: launchDate, startedAt: startedAt, timeout: timeout, probeID: probeID)
            }
            return
        }
        if isBoundsInTargetFrame(currentBounds, targetFrame: targetFrame) {
            // 窗口已在目标屏（可能已被 AXObserver/CG 链搬动）——停轮询链防重复 startStabilityCheck
            stopDetectionTimers(pid: pid)
            axFallbackProbeIDs.removeValue(forKey: pid)
            logger.info("AX 兜底: 窗口已在目标屏幕 pid=\(pid, privacy: .public)")
            return
        }
        // 停止 CG/AX 轮询链——避免 fallback 搬动后再命中重复搬动 + 双 stability timer
        stopDetectionTimers(pid: pid)
        axFallbackProbeIDs.removeValue(forKey: pid)
        logger.info("AX 兜底: 窗口不在目标屏幕，执行搬窗 pid=\(pid, privacy: .public) current=\(NSStringFromRect(currentBounds), privacy: .public) target=\(NSStringFromRect(targetFrame), privacy: .public)")
        hideMoveUnhide(axWindows: [mainWindow], targetFrame: targetFrame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
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
    /// unhide 失败（少数 App 第二次 set hidden 会失败）时 100ms 后重试一次，避免窗口永久不可见；
    /// 不支持 hidden 的 App（如微信）走 move-only
    private func hideMoveUnhide(axWindows: [AXUIElement], targetFrame: CGRect, prebuiltSize: CGSize? = nil) {
        // 仅对仍可访问的窗口走 hide 路径，已销毁的窗口跳过
        let alive: [AXUIElement] = axWindows.filter { AXWindowReader.isAlive($0) }

        // 记录 hidden 设置是否成功，失败的窗口直接 move 不尝试 unhide
        var hiddenSucceeded: [AXUIElement: Bool] = [:]
        for window in alive {
            let ok = setAXWindowHidden(window, hidden: true)
            hiddenSucceeded[window] = ok
            if !ok {
                logger.debug("hideMoveUnhide: hidden=true 设置失败，该窗口将走 move-only")
            }
        }

        // 2) Move: 居中放置（moveWindowToFrameImmediate 内部做 BL→TL 转换）
        for window in alive {
            moveWindowToFrameImmediate(window, targetFrame: targetFrame, prebuiltSize: prebuiltSize)
        }

        // 3) Unhide: 恢复窗口可见（hidden 设置失败的窗口跳过）
        for window in alive {
            guard hiddenSucceeded[window] == true else { continue }
            if !setAXWindowHidden(window, hidden: false) {
                let key = cooldownKey(axWindow: window)
                cooldowns.coolDown(key, duration: 0.1) { [weak self] in
                    guard let self = self, AXWindowReader.isAlive(window) else { return }
                    self.setAXWindowHidden(window, hidden: false)
                }
            }
        }

        // 4) unhide 后位置验证：macOS 可能在 unhide 时"纠正" Y 坐标，延迟回读修正
        //    （500ms 的 verifyAndRecenterWindow 只覆盖 moveWindowToTargetScreen 路径，这里补 150ms 快速验证）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            let visibleTL = self.visibleFrameToTL(targetFrame)
            for window in alive {
                guard AXWindowReader.isAlive(window) else { continue }
                guard let actualPos = AXWindowReader.position(window) else { continue }

                // 用 visibleFrame 重新计算期望位置（与 moveWindowToFrameImmediate 一致）
                let winSize = self.readWindowSizeFromAX(window, fallback: prebuiltSize)
                guard winSize.width > 0, winSize.height > 0 else { continue }
                let expectedY = visibleTL.origin.y + (visibleTL.height - winSize.height) / 2

                if abs(actualPos.y - expectedY) > 2 {
                    logger.warning("hideMoveUnhide: unhide 后 Y 被调整 actual=\(NSStringFromPoint(actualPos), privacy: .public) expectedY=\(expectedY, privacy: .public) → 重新设置")
                    var pos = actualPos
                    pos.y = expectedY
                    if let posValue = AXValueCreate(.cgPoint, &pos) {
                        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
                    }
                }
            }
        }
    }

    /// 生成冷却注册表的 key
    /// windowID → 移动冷却（"move:"）；AXUIElement pointer → unhide 重试冷却（"unhide:"）
    /// pointer 用 Unmanaged opaque 地址——AXUIElement 生命周期内稳定，释放后被复用属理论风险
    private func cooldownKey(windowID: String? = nil, axWindow: AXUIElement? = nil) -> String {
        if let wid = windowID { return "move:\(wid)" }
        if let win = axWindow {
            // 用 opaque pointer（AXUIElement CFTypeRef 内存地址）替代 ObjectIdentifier.hashValue
            let ptr = Unmanaged<AXUIElement>.passUnretained(win).toOpaque()
            return "unhide:\(ptr)"
        }
        return "unknown"
    }

    /// 通过 CGWindowList 找指定 PID 的第一个普通 on-screen 窗口 bounds
    /// 过滤：ownerPID 匹配 + layer==0（非浮层）+ alpha>0（非透明）+ 宽高≥50（非瞬时态）
    /// 优先返回有标题的窗口，避免极小工具窗口被误选为主窗口
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

            // 优先有 title 的窗口（kCGWindowName 非空）
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

    /// 一次性获取所有 on-screen 窗口并按 pid 分组，避免逐 App 调用 CGWindowListCopyWindowInfo
    /// 返回每 pid 所有候选窗口（有 title 全部 + 无 title 但 ≥50），按面积降序——
    /// 多窗口应用只取最大窗口会让小窗口不被轮询覆盖。过滤与 handlePinWindowCreated 的 ≥50 一致
    private func fetchAllOnScreenWindowBounds() -> [pid_t: [CGRect]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        // pid → 候选窗口列表，收集后按面积降序（首个即旧逻辑中的"主窗口"）
        var candidates: [pid_t: [(bounds: CGRect, area: CGFloat)]] = [:]

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

            // 有 title 的窗口全部收集；无 title 的需满足最小尺寸（过滤瞬时/辅助窗口）
            if hasTitle || (width >= 50 && height >= 50) {
                candidates[ownerPID, default: []].append((bounds, area))
            }
        }

        var result: [pid_t: [CGRect]] = [:]
        for (pid, list) in candidates {
            result[pid] = list.sorted { $0.area > $1.area }.map { $0.bounds }
        }
        return result
    }

    /// 在 AX 窗口列表中按 (position, size) 容差匹配，拿到与 CGWindowList 同一窗口对应的 AXUIElement
    /// 容差 1.0 像素，覆盖浮点精度问题
    private func matchAXWindow(for pid: pid_t, targetBounds: CGRect) -> AXUIElement? {
        guard let windows = AXWindowReader.windows(pid: pid) else {
            return nil
        }

        for window in windows {
            guard let position = AXWindowReader.position(window),
                  let size = AXWindowReader.size(window) else {
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
    /// 双链并行检测（CGWindowList + AX 兜底），任一命中即搬动；1.5-2s 内每 100ms 校验，回弹再搬
    /// 每个 pid 独立 DetectionContext；记录 launchDate 防 PID 复用误命中
    private func earlyWindowCatcher(pid: pid_t, targetFrame: CGRect, titlePattern: String? = nil) {
        // 同 pid 已有上下文在跑 → 取消旧上下文（用户重启 App 的场景）
        if let existing = activeDetections[pid] {
            existing.cancel()
            activeDetections.removeValue(forKey: pid)
        }
        // 抓取 launchDate 用于 PID 复用防御
        let launchDate = NSRunningApplication(processIdentifier: pid)?.launchDate
        let detectionTimeout: TimeInterval = 5.0
        let context = DetectionContext(pid: pid, targetFrame: targetFrame, launchDate: launchDate, titlePattern: titlePattern)
        activeDetections[pid] = context

        // 链 A：CGWindowList 高频轮询（启动期 24ms≈40Hz 抢首帧，运行期 33ms 控 CPU）
        // 24ms 比 16ms 检测延迟仅增 8ms，CG 快照轮询 CPU 减半
        startCGDetectionTimer(context: context, timeout: detectionTimeout, interval: 0.024)
        // 链 B：AX 100ms 兜底（无 Screen Recording 权限时仍能工作）
        startAXDetectionTimer(context: context, timeout: detectionTimeout)
    }

    /// 链 A：CGWindowList 高频轮询（DispatchSourceTimer 实现，无栈增长）
    /// interval 为 nil 时用全局 cgDetectionInterval（33ms 运行期默认）
    private func startCGDetectionTimer(context: DetectionContext, timeout: TimeInterval, interval: TimeInterval? = nil) {
        let pid = context.pid
        let targetFrame = context.targetFrame
        let stopFlag = context.stopFlag
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let tickInterval = interval ?? cgDetectionInterval
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(tickInterval * 1000)), leeway: .milliseconds(2))
        let startTime = Date()
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if stopFlag.isSet { self.cancelDetectionContext(pid: pid); return }
            if Date().timeIntervalSince(startTime) > timeout { self.cancelDetectionContext(pid: pid); return }
            // 0-PID 防御；PID 复用防御（launchDate 校验）
            guard pid > 0, context.isPIDStillOriginal() else {
                self.cancelDetectionContext(pid: pid); return
            }
            // 目标屏已不存在则放弃
            guard self.isTargetScreenAvailable(targetFrame) else { self.cancelDetectionContext(pid: pid); return }

            if let bounds = self.findOnScreenWindow(for: pid) {
                if stopFlag.trySet() {
                    // 停 CG/AX timer 但保留 context（供 startStabilityCheck 使用 originalLaunchDate）
                    self.stopDetectionTimers(pid: pid)
                    self.onWindowDetected(pid: pid, targetFrame: targetFrame, initialBounds: bounds)
                }
                return
            }
        }
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
            // 0-PID 防御；PID 复用防御
            guard pid > 0, context.isPIDStillOriginal() else {
                self.cancelDetectionContext(pid: pid); return
            }
            // 目标屏已不存在则放弃
            guard self.isTargetScreenAvailable(targetFrame) else { self.cancelDetectionContext(pid: pid); return }

            if let windows = AXWindowReader.windows(pid: pid), !windows.isEmpty {
                if stopFlag.trySet() {
                    // 停 AX timer 但保留 context
                    self.stopDetectionTimers(pid: pid)
                    self.onWindowDetected(pid: pid, targetFrame: targetFrame, axWindows: windows)
                }
                return
            }
        }
        context.axTimer?.cancel()
        context.axTimer = timer
        timer.resume()
    }

    /// 取消某个 pid 的检测上下文（含所有 timer）
    /// 同步清理 stabilityCount，避免 cancel 后遗留 pid 计数
    private func cancelDetectionContext(pid: pid_t) {
        guard let context = activeDetections[pid] else { return }
        context.cancel()
        activeDetections.removeValue(forKey: pid)
        stabilityCount.removeValue(forKey: pid)
    }

    /// 停止 CG/AX 检测 timer 但保留 context——供 startStabilityCheck 后续
    /// 使用 originalLaunchDate 做 PID 复用防御；context 仍留在 activeDetections 中
    private func stopDetectionTimers(pid: pid_t) {
        guard let context = activeDetections[pid] else { return }
        context.cgTimer?.cancel(); context.cgTimer = nil
        context.axTimer?.cancel(); context.axTimer = nil
        context.stopFlag.set()
    }

    /// 校验目标屏幕 frame 仍在当前屏幕拓扑中
    /// visibleFrame 容差（避免 Dock 高度变化时误判）
    private static let screenFrameTolerance: CGFloat = 1.0

    /// 判断目标屏幕 frame 是否仍可识别——统一走 ScreenManager.screens
    private func isTargetScreenAvailable(_ targetFrame: CGRect) -> Bool {
        return screenManager.screens.contains { abs($0.frame.minX - targetFrame.minX) < Self.screenFrameTolerance
            && abs($0.frame.minY - targetFrame.minY) < Self.screenFrameTolerance
            && abs($0.frame.width - targetFrame.width) < Self.screenFrameTolerance
            && abs($0.frame.height - targetFrame.height) < Self.screenFrameTolerance
        }
    }

    /// 窗口被检测到（CG 链命中）：用 bounds 匹配 AXUIElement 再移动
    /// PID 复用防御走 activeDetections 内 originalLaunchDate
    /// matchAXWindow 失败时只记日志——避免误搬 IDE 等应用的辅助窗口
    private func onWindowDetected(pid: pid_t, targetFrame: CGRect, initialBounds: CGRect) {
        // PID 复用防御——context 仍在 activeDetections（stopDetectionTimers 未删除）
        if let context = activeDetections[pid], !context.isPIDStillOriginal() {
            logger.error("onWindowDetected(CG) PID 已被复用: pid=\(pid), 放弃搬动")
            cancelDetectionContext(pid: pid)
            return
        }

        // 用 CG bounds 去 AX 列表里匹配同一个窗口
        if let axWindow = matchAXWindow(for: pid, targetBounds: initialBounds) {
            // hide → move → unhide，让用户看不到"错误屏幕位置"那一两帧
            hideMoveUnhide(axWindows: [axWindow], targetFrame: targetFrame)
        } else {
            // CG/AX 精确匹配失败时（如微信），回退到 pickMainWindow
            // 从 AX 窗口列表中挑主窗口搬动，与 onWindowDetected(AX) 路径保持一致
            logger.warning("onWindowDetected(CG) matchAXWindow 失败，回退 pickMainWindow: pid=\(pid) initialBounds=\(NSStringFromRect(initialBounds), privacy: .public)")
            if let axWindows = AXWindowReader.windows(pid: pid) {
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

        // 延迟 120ms 让 unhide 100ms 重试先完成，避免"刚搬完又再搬一次"回弹
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
        }
    }

    /// 窗口被检测到（AX 链命中，CG 链不命中时使用）
    /// 只搬主窗口（有 title 或面积最大）——多窗口 App 的辅助窗口全部居中会重叠在中心点；
    /// 支持 windowTitlePattern 按标题过滤
    private func onWindowDetected(pid: pid_t, targetFrame: CGRect, axWindows: [AXUIElement]) {
        if let context = activeDetections[pid], !context.isPIDStillOriginal() {
            logger.error("onWindowDetected(AX) PID 已被复用: pid=\(pid), 放弃搬动")
            cancelDetectionContext(pid: pid)
            return
        }

        // 按标题过滤窗口
        let titlePattern = activeDetections[pid]?.titlePattern
        let filteredWindows = filterWindowsByTitle(axWindows, pattern: titlePattern)
        guard !filteredWindows.isEmpty else {
            logger.debug("onWindowDetected(AX) 窗口标题不匹配 pattern: pid=\(pid) pattern=\(titlePattern ?? "<nil>", privacy: .public)")
            return
        }

        // 挑主窗口：优先有 title 的（IDE 主窗口/Safari 标签等），否则挑面积最大的
        if let mainWindow = pickMainWindow(from: filteredWindows) {
            hideMoveUnhide(axWindows: [mainWindow], targetFrame: targetFrame)
        } else {
            logger.error("onWindowDetected(AX) 挑不出主窗口: pid=\(pid) windowsCount=\(filteredWindows.count), 放弃搬动")
        }

        // 延迟 120ms 让 unhide 重试先完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
        }
    }

    /// 按窗口标题过滤：nil/空 = 匹配所有（默认）；非空 = 标题包含该字符串（大小写不敏感）
    private func filterWindowsByTitle(_ windows: [AXUIElement], pattern: String?) -> [AXUIElement] {
        guard let pattern = pattern, !pattern.isEmpty else {
            return windows // 无 pattern = 匹配所有
        }
        return windows.filter { window in
            guard let title = AXWindowReader.string(window, kAXTitleAttribute as String), !title.isEmpty else {
                return false // 无标题的窗口在 pattern 模式下不匹配
            }
            return title.localizedCaseInsensitiveContains(pattern)
        }
    }

    /// 挑主窗口——优先有 title 的；无 title 时挑面积最大的；都拿不到返回 nil
    private func pickMainWindow(from windows: [AXUIElement]) -> AXUIElement? {
        var withTitle: [(AXUIElement, CGRect)] = []
        var maxArea: CGFloat = 0
        var largestWindow: AXUIElement?

        for window in windows {
            guard let bounds = AXWindowReader.bounds(window) else { continue }

            let hasTitle = !(AXWindowReader.string(window, kAXTitleAttribute as String) ?? "").isEmpty

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
        if let main = largestWindow, maxArea > 0 {
            return main
        }
        return nil
    }

    /// 稳态校验：1.5-2s 内每 100ms 检查一次，回弹立刻再搬，连续 3 次稳定则停
    /// stabilityTimer 写入 context 自身；命中稳定或超时后完整清理 activeDetections + stabilityCount
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
            guard self.activeDetections[pid] != nil else { timer.cancel(); return }
            // 0-PID 防御 + PID 复用防御（用 context 内的 originalLaunchDate）
            guard pid > 0, context.isPIDStillOriginal() else {
                timer.cancel()
                self.cancelDetectionContext(pid: pid)
                return
            }
            if Date().timeIntervalSince(startTime) > maxDuration {
                timer.cancel()
                // 超时分支也清理 activeDetections + stabilityCount，避免 context 累积
                self.activeDetections[pid]?.stabilityTimer = nil
                self.activeDetections.removeValue(forKey: pid)
                self.stabilityCount.removeValue(forKey: pid)
                return
            }
            // 目标屏已拔出：同步清理 context + stabilityCount，避免永久残留
            guard self.isTargetScreenAvailable(targetFrame) else {
                timer.cancel()
                self.activeDetections[pid]?.stabilityTimer = nil
                self.activeDetections.removeValue(forKey: pid)
                self.stabilityCount.removeValue(forKey: pid)
                return
            }

            let currentBounds = self.findOnScreenWindow(for: pid)
            let isStable = currentBounds.map { self.isBoundsInTargetFrame($0, targetFrame: targetFrame) } ?? false

            if isStable {
                self.stabilityCount[pid, default: 0] += 1
                if self.stabilityCount[pid, default: 0] >= requiredStableCount {
                    timer.cancel()
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
                } else if currentBounds != nil {
                    // matchAXWindow 精确匹配失败时，回退到 pickMainWindow 兜底
                    // 与 onWindowDetected(CG) 路径保持一致
                    if let axWindows = AXWindowReader.windows(pid: pid),
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
    /// 实现外移至 SwallowScreenCore.ScreenGeometry（纯函数，供单测覆盖），此处仅转发
    private func isBoundsInTargetFrame(_ bounds: CGRect, targetFrame: CGRect) -> Bool {
        ScreenGeometry.isBoundsInTargetFrame(bounds, targetFrame: targetFrame, screenHeight: primaryScreenHeight)
    }

    /// CGWindowList 看不到窗口时，直接通过 AX API 获取并搬动窗口
    /// - Returns: 是否成功找到并尝试搬动至少一个 AX 窗口
    /// 只搬主窗口，避免多窗口 App 的辅助窗口被误搬
    private func moveAXWindowsToTargetFrame(for pid: pid_t, targetFrame: CGRect) -> Bool {
        guard let axWindows = AXWindowReader.windows(pid: pid), !axWindows.isEmpty else {
            return false
        }

        // 只挑主窗口搬动，不搬辅助窗口
        guard let mainWindow = pickMainWindow(from: axWindows) else {
            return false
        }

        guard AXWindowReader.bounds(mainWindow) != nil else { return false }

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

        // 在 startMonitoring 中注册应用启动监听，确保不丢失 SwallowScreen 启动后
        // 1s 延迟期间发生的应用启动通知。去重：token 已存在则跳过。
        setupAppLaunchObserver()

        // 入口完整重置状态，避免 stopMonitoring 中途失败时状态不一致
        lastAppsFingerprint = 0
        cachedPinnedApps = []
        isPerformingInitialMove = false
        moveAllAppsTask?.cancel()
        moveAllAppsTask = nil
        // 重置移动/守卫/重试冷却键
        // 注意保留 axFallback/axTimeout/fsExit 键（stopMonitoring 同样保留 fsExit）
        cooldowns.removeKeys { key in
            key.hasPrefix("move:") || key.hasPrefix("moving:") || key.hasPrefix("unhide:")
        }
        previousWindowPositions.removeAll()
        previousWindowPositionsOrder.removeAll()
        // 同步清理 Set
        previousWindowPositionsOrderSet.removeAll()
        stabilityCount.removeAll()

        // 启动期标志开启；checkAndEnforcePinnedWindows 期间会跳过 pinToScreen 分支
        isPerformingInitialMove = true
        // 启动期分批串行，避免瞬时 fan-out 过多 DispatchSourceTimer
        // task 句柄保存到 moveAllAppsTask，stopMonitoring 中可取消
        moveAllAppsTask = Task { @MainActor [weak self] in
            await self?.moveAllOpenAppsToAssignedScreens()
            self?.isPerformingInitialMove = false
            self?.moveAllAppsTask = nil
        }

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
    /// 走 earlyWindowCatcher（与 handleAppLaunch 共享搬动 + 稳态校验链路）；每批后
    /// await Task.yield() 避免主 RunLoop 过载；目标屏统一走 ScreenManager.resolveTarget
    private func moveAllOpenAppsToAssignedScreens() async {
        guard let modelContext = modelContext else { return }

        if !AXIsProcessTrusted() {
            return
        }

        // 只拉启用 App；循环内 guard isEnabled 保留作防御；sortBy 保证 fetch 顺序稳定
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.bundleIdentifier)]
        )
        guard let allApps = try? modelContext.fetch(descriptor) else { return }

        // 一次性获取所有 on-screen 窗口，避免逐应用调用 CGWindowListCopyWindowInfo
        let allOnScreenWindows = fetchAllOnScreenWindowBounds()

        // 预构建 bundleID → pid 字典，避免循环内重复查找
        let runningApps = NSWorkspace.shared.runningApplications
        var bundleIDToPid: [String: pid_t] = [:]
        var pidToApp: [pid_t: NSRunningApplication] = [:]
        for app in runningApps {
            if let bid = app.bundleIdentifier {
                bundleIDToPid[bid] = app.processIdentifier
            }
            pidToApp[app.processIdentifier] = app
        }

        // 目标屏解析统一走 ScreenManager.resolveTarget

        // 每批最多处理 5 个 app 后让出主 RunLoop
        let batchSize = 5
        var processedInBatch = 0

        for appInfo in allApps {
            // 只有启用状态且设置了目标屏幕才处理
            guard appInfo.isEnabled else { continue }
            guard appInfo.targetScreenID != nil || appInfo.targetScreenSerialNumber != nil || appInfo.targetScreenName != nil else { continue }

            guard let resolved = screenManager.resolveTarget(for: appInfo) else {
                // 与 handleAppLaunch 一致：匹配失败时输出日志便于定位
                logger.error("未找到 App 配置的目标屏幕（启动时）: bundleID=\(appInfo.bundleIdentifier, privacy: .public) targetScreenID=\(String(describing: appInfo.targetScreenID), privacy: .public) targetScreenSerialNumber=\(appInfo.targetScreenSerialNumber ?? "<nil>", privacy: .public) targetScreenName=\(appInfo.targetScreenName ?? "<nil>", privacy: .public)")
                continue
            }

            guard let pid = bundleIDToPid[appInfo.bundleIdentifier] else { continue }

            // 启动搬窗以面积最大的窗口（首个候选）为准，其余窗口由 100ms 轮询路径覆盖
            if let bounds = allOnScreenWindows[pid]?.first {
                if isBoundsInTargetFrame(bounds, targetFrame: resolved.visibleFrame) {
                    // 窗口已在目标屏幕——跳过
                    logger.debug("启动搬窗: 已在目标屏幕，跳过: bundleID=\(appInfo.bundleIdentifier, privacy: .public)")
                    continue
                }
                logger.info("启动搬窗: 调用 checkWindowPosition: bundleID=\(appInfo.bundleIdentifier, privacy: .public) screenID=\(resolved.id) targetFrame=\(NSStringFromRect(resolved.visibleFrame), privacy: .public)")
                checkWindowPosition(pid: pid, screenFrame: resolved.frame, targetFrame: resolved.visibleFrame, appBundleID: appInfo.bundleIdentifier, screenID: resolved.id, prebuiltMainBounds: bounds)
            } else {
                logger.debug("启动搬窗: CG 无可见窗口，尝试 AX 直接搬窗: bundleID=\(appInfo.bundleIdentifier, privacy: .public)")
                if !moveAXWindowsToTargetFrame(for: pid, targetFrame: resolved.visibleFrame) {
                    logger.debug("启动搬窗: AX 也无窗口，earlyWindowCatcher 兜底: bundleID=\(appInfo.bundleIdentifier, privacy: .public)")
                    earlyWindowCatcher(pid: pid, targetFrame: resolved.visibleFrame, titlePattern: appInfo.windowTitlePattern)
                }
            }

            processedInBatch += 1
            if processedInBatch >= batchSize {
                processedInBatch = 0
                // 让出主 RunLoop，避免 detection timer 全部堆积
                await Task.yield()
            }
        }
    }
    
    func stopMonitoring() {
        moveAllAppsTask?.cancel()
        moveAllAppsTask = nil
        isPerformingInitialMove = false
        timer?.cancel()
        timer = nil
        isMonitoring = false
        // 清除 AX 兜底探测链 ID——已入队的 tick 会自停止
        axFallbackProbeIDs.removeAll()
        // 清移动/守卫/重试/兜底/超时冷却键
        // fsExit 保留：stopMonitoring 不清退出全屏冷却，
        // 避免 stop→start 3s 内全屏窗口重复触发退出动画
        cooldowns.removeKeys { key in
            !key.hasPrefix("fsExit:")
        }
        previousWindowPositions.removeAll()
        previousWindowPositionsOrder.removeAll()
        // 同步清理 Set
        previousWindowPositionsOrderSet.removeAll()
        for context in activeDetections.values { context.cancel() }
        activeDetections.removeAll()
        stabilityCount.removeAll()
        lastAppsFingerprint = 0
        cachedPinnedApps = []
        // AXObserver 清理
        // 使用 CFRunLoopGetMain() 而非 CFRunLoopGetCurrent()，
        // source 加在主 RunLoop 上，必须从主 RunLoop 移除
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
    /// AppInfo 指纹不变时跳过 fetch 后逻辑；启动期跳过 pinToScreen，避免与 moveAll 竞争 activeDetections
    // 调试计数器——确认 checkAndEnforcePinnedWindows 被调用的频率
    private var checkCallCount: Int = 0

    private func checkAndEnforcePinnedWindows() {
        self.checkCallCount += 1
        let count = self.checkCallCount
        if count <= 5 || count % 30 == 0 {
            logger.debug("checkAndEnforcePinnedWindows: 被调用 #\(count)")
        }

        // Dock/菜单栏自动隐藏只改 visibleFrame，不触发 didChangeScreenParameters 通知；
        // 每 2s（20 个 100ms tick）兜底刷新一次屏幕列表
        if count % 20 == 0 {
            screenManager.refreshScreens()
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

        // 只拉启用 App（避免全表拉取）；sortBy 保证指纹计算顺序稳定；
        // 指纹未变时复用 cachedPinnedApps，避免每 100ms 都 fetch
        let newFingerprint: Int
        let allApps: [AppInfo]
        // 去掉"缓存非空则跳过 fetch"的快速路径——SwiftData 数据可能被 UI 修改
        // （如关闭 pinToScreen），快速路径无法检测到变化，导致 cachedPinnedApps 永远不刷新，
        // pinObserver 永远不移除。改为每次都 fetch + 计算指纹，仅在指纹变化时才刷新缓存和 pinObserver
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

        // 每次 check 末尾清理无界增长的窗口字典
        trimWindowDictionariesIfNeeded()

        // 启动期内跳过 pinToScreen，避免与 moveAll 冲突
        if isPerformingInitialMove { return }

        // 没有任何 App 开启 pinToScreen 时，不进 checkWindowPosition 循环
        if cachedPinnedApps.isEmpty {
            return
        }

        // 屏幕列表由 ScreenManager 统一维护

        // 一次性获取所有 running apps，避免循环内多次调用 runningApplications(withBundleIdentifier:)
        let runningApps = NSWorkspace.shared.runningApplications
        var runningAppByBundleID: [String: NSRunningApplication] = [:]
        for app in runningApps {
            if let bid = app.bundleIdentifier {
                runningAppByBundleID[bid] = app
            }
        }

        let pinnedApps = cachedPinnedApps
        if pinnedApps.isEmpty {
            // 无 pinned app 时清理所有 pinObserver
            // 先收集要移除的 pid，避免遍历中修改字典导致未定义行为
            let pidsToRemove = Array(pinObservers.keys)
            for pid in pidsToRemove {
                removePinObserver(for: pid)
            }
            return
        }

        // 一次性获取所有 on-screen 窗口，避免每个 App 单独调用 CGWindowListCopyWindowInfo
        let allOnScreenWindows = fetchAllOnScreenWindowBounds()

        for appInfo in pinnedApps {
            guard let resolved = screenManager.resolveTarget(for: appInfo) else { continue }

            guard let app = runningAppByBundleID[appInfo.bundleIdentifier] else { continue }

            let pid = app.processIdentifier
            let windowID = "\(pid)-main"

            // 用户正在拖拽该窗口时跳过，等松手后再检查
            if pendingDragCheckPids.contains(pid) { continue }

            // 检查该 pid 的**所有**候选窗口（面积降序），不再只查面积最大的一个——
            // 多窗口应用（如 Windows App 会话窗+连接列表窗）中小窗口此前不被轮询覆盖
            let windowBoundsList = allOnScreenWindows[pid] ?? []
            for (index, bounds) in windowBoundsList.enumerated() {
                // 首窗口沿用 "\(pid)-main" 保持与既有冷却/位置记录兼容，其余窗口追加索引后缀
                let wid = index == 0 ? windowID : "\(windowID)-\(index)"
                // 各窗口独立冷却检查，避免无意义的 AX 调用
                if cooldowns.isCoolingDown("move:\(wid)") || cooldowns.isCoolingDown("moving:\(wid)") { continue }
                checkWindowPosition(pid: pid, screenFrame: resolved.frame, targetFrame: resolved.visibleFrame, appBundleID: appInfo.bundleIdentifier, screenID: resolved.id, prebuiltMainBounds: bounds, windowKey: wid)
            }
        }

        // 本轮扫到的存活 pids——previousWindowPositions 中其他 pid 前缀视为死键
        // 补充 didTerminateApplicationNotification 漏掉的边界（App 突然消失/异常退出路径）
        let alivePids: Set<pid_t> = Set(pinnedApps.compactMap {
            runningAppByBundleID[$0.bundleIdentifier]?.processIdentifier
        })
        removeDeadKeys(forAlivePids: alivePids)
    }

    /// 清理 previousWindowPositions / axMetadataCache 中已不存在运行实例的 pid 前缀
    private func removeDeadKeys(forAlivePids alivePids: Set<pid_t>) {
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

    /// 计算 AppInfo 列表的指纹（用于短路未变化的轮询）
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

    // 字典增长上限：超过 200 条时按插入顺序清理最旧的一半
    private static let windowDictionaryMaxCount = 200
    private func trimWindowDictionariesIfNeeded() {
        if previousWindowPositions.count > Self.windowDictionaryMaxCount {
            let removeCount = Self.windowDictionaryMaxCount / 2
            // 按插入顺序数组删最旧的一半，同步清 Set
            let keysToRemove = Array(previousWindowPositionsOrder.prefix(removeCount))
            for key in keysToRemove {
                previousWindowPositions.removeValue(forKey: key)
                previousWindowPositionsOrderSet.remove(key)
            }
            previousWindowPositionsOrder.removeFirst(removeCount)
            // 字典清理频率低，用 logger.debug
            logger.debug("previousWindowPositions 触发清理: 移除 \(removeCount) 条，剩余 \(self.previousWindowPositions.count)")
        }
        // axMetadataCache 上限：位置 key 按 50px 网格分桶，窗口移动后旧 key 失效，
        // 无法精确追踪 LRU，超过 200 时直接砍掉前一半
        if axMetadataCache.count > Self.windowDictionaryMaxCount {
            let removeCount = axMetadataCache.count - Self.windowDictionaryMaxCount
            let keys = Array(axMetadataCache.keys.prefix(removeCount))
            for key in keys { axMetadataCache.removeValue(forKey: key) }
        }
        // moving 进行中守卫上限清理
        // 先取一次 count 再判定，避免同谓词重复遍历
        let movingCount = cooldowns.count(where: { $0.hasPrefix("moving:") })
        if movingCount > Self.windowDictionaryMaxCount {
            let removed = cooldowns.removeOldest(Self.windowDictionaryMaxCount / 2, where: { $0.hasPrefix("moving:") })
            logger.debug("movingWindows 触发清理: 移除 \(removed) 条，剩余 \(movingCount - removed)")
        }
        // 移动冷却键无显式上限：启动期 moveAllOpenAppsToAssignedScreens
        // 可能一次插入 N 条，5s 后才由冷却到期清理；加 200 上限兜底
        let moveCount = cooldowns.count(where: { $0.hasPrefix("move:") })
        if moveCount > Self.windowDictionaryMaxCount {
            cooldowns.removeOldest(Self.windowDictionaryMaxCount / 2, where: { $0.hasPrefix("move:") })
        }
        // move:+unhide: 冷却条目无显式上限——正常 5s 后自清理，
        // 但主线程阻塞时可能累积；超限时删到上限为止
        let retryCount = cooldowns.count(where: { $0.hasPrefix("move:") || $0.hasPrefix("unhide:") })
        if retryCount > Self.windowDictionaryMaxCount {
            cooldowns.removeOldest(retryCount - Self.windowDictionaryMaxCount, where: { $0.hasPrefix("move:") || $0.hasPrefix("unhide:") })
        }
    }
    
    /// 简单的"一次性触发"标记，用于双链并行检测中让先命中的链通知另一链停止
    /// 标 Sendable + 方法 nonisolated，消除 Swift 6 strict concurrency 警告
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

    /// 单个 App 检测上下文（CG/AX 链 + 稳态校验）
    /// 自身持有 timer；WindowMover 仅在 activeDetections 字典中持有引用
    @MainActor
    private final class DetectionContext {
        let pid: pid_t
        let targetFrame: CGRect
        let titlePattern: String?
        // AtomicFlag 已标 Sendable + 方法 nonisolated，无需 nonisolated(unsafe)
        let stopFlag: AtomicFlag
        // 记录首次拿到 pid 时的 launchDate；timer 触发时校验，
        // 防止原 App 被 kill 后新 App 复用同一 pid 误命中
        let originalLaunchDate: Date?
        // nonisolated(unsafe)：DispatchSourceTimer 是 GCD 类型，
        // cancel() 文档保证线程安全；只在 cancel() 内部访问；
        // 让 cancel() 可以从 deinit（非 MainActor）调用
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

        // nonisolated 让 deinit 可以调用——AtomicFlag / DispatchSourceTimer
        // 都是线程安全类型
        nonisolated func cancel() {
            stopFlag.set()
            cgTimer?.cancel(); cgTimer = nil
            axTimer?.cancel(); axTimer = nil
            stabilityTimer?.cancel(); stabilityTimer = nil
        }

        /// 校验 pid 仍然属于原 App（launchDate 匹配）；不匹配说明 PID 已被复用
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
    
    /// 屏变化处理——屏幕缓存已移至 ScreenManager，这里只清 pin 侧缓存
    /// nonisolated：允许从 NotificationCenter observer 等非隔离上下文直接调用
    nonisolated func handleScreenConfigurationChanged() {
        Task { @MainActor in
            // 屏幕拓扑变化后 pinTargetCache 中的 frame 可能已失效，需要重建
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

    /// 检查窗口位置并处理
    /// 判定：窗口中心点或 50% 面积在目标屏 visibleFrame 内
    /// AX 元数据缓存（title/role/size 按位置 50px 网格分桶）：窗口静止时 AX 调用从 4 降到 1
    /// Electron（如 CherryStudio）kAXWindowsAttribute 常返回空，改用 CGWindowList 做位置检测，
    /// 只在需要移动时才用 AX 获取窗口引用
    /// prebuiltMainBounds 避免循环内重复 CGWindowListCopyWindowInfo；fastPath 跳过 CGWindowList 扫描
    private func checkWindowPosition(pid: pid_t, screenFrame: CGRect, targetFrame: CGRect, appBundleID: String, screenID: UInt32, prebuiltMainBounds: CGRect? = nil, fastPath: Bool = false, windowKey: String? = nil) {
        if fastPath {
            // 直接用 AX 读主窗口位置并判断，跳过 CGWindowList
            checkWindowPositionFastPath(pid: pid, screenFrame: screenFrame, targetFrame: targetFrame, screenID: screenID)
            return
        }

        // 优先使用预计算的 bounds；兜底才走单点 CGWindowList 查询（供早期检测路径复用）
        guard let bounds = prebuiltMainBounds ?? findOnScreenWindow(for: pid) else { return }

        // windowID 支持外部指定：轮询路径逐窗口检查时每窗口一个独立标识
        let windowID = windowKey ?? "\(pid)-main"

        // 用 CGWindowList 的位置直接判断是否在目标屏
        if isBoundsInTargetFrame(bounds, targetFrame: targetFrame) {
            previousWindowPositions[windowID] = bounds.origin
            if !previousWindowPositionsOrderSet.contains(windowID) {
                previousWindowPositionsOrder.append(windowID)
                previousWindowPositionsOrderSet.insert(windowID)
            }
            return
        }

        // 冷却检查（外层已过滤，保留作为防御）
        if cooldowns.isCoolingDown("move:\(windowID)") || cooldowns.isCoolingDown("moving:\(windowID)") { return }

        // 通过 AX 获取窗口引用（只尝试一次，不遍历所有 AX 窗口）
        guard let axWindows = AXWindowReader.windows(pid: pid) else { return }

        // 找位置最接近 CGWindowList 结果的 AX 窗口
        var bestWindow: AXUIElement? = nil
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for axWindow in axWindows {
            guard let axPosition = AXWindowReader.position(axWindow) else { continue }
            let dx = axPosition.x - bounds.origin.x
            let dy = axPosition.y - bounds.origin.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestWindow = axWindow
            }
        }

        guard let targetWindow = bestWindow else { return }

        // 全屏窗口在独立 Space，AX kAXPositionAttribute 设置被系统忽略——
        // 方案 A：先退出全屏（退出后不自动重进），下一轮轮询以普通窗口身份搬回目标屏
        if isWindowFullScreen(targetWindow) {
            triggerExitFullScreen(pid: pid, window: targetWindow, windowID: windowID)
            return
        }

        // 执行移动
        cooldowns.hold("moving:\(windowID)")
        // 传入 bounds.size 作为 prebuiltSize，避免 AX 读取 size 失败导致居中偏移
        moveWindowToTargetScreen(targetWindow, screenFrame: screenFrame, visibleFrame: targetFrame, windowID: windowID, prebuiltSize: bounds.size)
    }

    /// pinObserver 快速路径——直接用 AX 读位置 + 移动，跳过 CGWindowList 扫描（省 ~50-100ms）
    /// AX 失败（如 Electron）回退 CGWindowList 路径；缓存主窗口引用，省 kAXWindowsAttribute 查询（~5-15ms）
    private func checkWindowPositionFastPath(pid: pid_t, screenFrame: CGRect, targetFrame: CGRect, screenID: UInt32) {
        let windowID = "\(pid)-main"

        // 优先使用缓存的主窗口引用
        let targetWindow: AXUIElement
        if let cached = pinWindowCache[pid] {
            targetWindow = cached
        } else {
            guard let axWindows = AXWindowReader.windows(pid: pid), !axWindows.isEmpty else {
                // AX 失败（如 Electron 应用）——回退到 CGWindowList 路径
                checkWindowPosition(pid: pid, screenFrame: screenFrame, targetFrame: targetFrame, appBundleID: "", screenID: screenID)
                return
            }

            // 找主窗口：优先找 kAXMainAttribute == true 的窗口，否则取第一个
            var mainWindow: AXUIElement? = nil
            for axWindow in axWindows {
                if AXWindowReader.bool(axWindow, kAXMainAttribute as String) == true {
                    mainWindow = axWindow
                    break
                }
            }
            targetWindow = mainWindow ?? axWindows[0]
            pinWindowCache[pid] = targetWindow
        }

        // 读取窗口位置
        guard let position = AXWindowReader.position(targetWindow) else {
            // 无法读取位置——缓存可能失效，清除后回退
            pinWindowCache.removeValue(forKey: pid)
            pinWindowSizeCache.removeValue(forKey: pid)
            checkWindowPosition(pid: pid, screenFrame: screenFrame, targetFrame: targetFrame, appBundleID: "", screenID: screenID)
            return
        }

        // size 也缓存；超过 TTL 强制重读，保证窗口 resize 后尺寸新鲜
        var size = CGSize.zero
        if let cached = pinWindowSizeCache[pid],
           Date().timeIntervalSince(cached.cachedAt) < Self.pinWindowSizeCacheTTL {
            size = cached.size
        } else {
            if let cachedSize = AXWindowReader.size(targetWindow) {
                size = cachedSize
                pinWindowSizeCache[pid] = (size, Date())
            }
        }

        let bounds = CGRect(origin: position, size: size)

        if isBoundsInTargetFrame(bounds, targetFrame: targetFrame) {
            previousWindowPositions[windowID] = bounds.origin
            if !previousWindowPositionsOrderSet.contains(windowID) {
                previousWindowPositionsOrder.append(windowID)
                previousWindowPositionsOrderSet.insert(windowID)
            }
            return
        }

        // 窗口不在目标屏——冷却检查（与 checkWindowPosition 普通路径一致，在位置判断之后）
        if cooldowns.isCoolingDown("move:\(windowID)") || cooldowns.isCoolingDown("moving:\(windowID)") { return }

        // fastPath 同样可能命中全屏主窗口——先退出全屏再搬（方案 A）
        if isWindowFullScreen(targetWindow) {
            triggerExitFullScreen(pid: pid, window: targetWindow, windowID: windowID)
            return
        }

        // 直接移动（已有 AX 窗口引用）；传 bounds.size 作 prebuiltSize，避免 AX 读 size 失败导致居中偏移
        cooldowns.hold("moving:\(windowID)")
        moveWindowToTargetScreen(targetWindow, screenFrame: screenFrame, visibleFrame: targetFrame, windowID: windowID, prebuiltSize: bounds.size)
    }

    // MARK: - 全屏窗口处理（方案 A：退出全屏 → 移动，不自动重进）

    /// 判断 AX 窗口是否处于 macOS 原生全屏态
    /// 信号 1：subrole == AXFullScreenWindow（全屏窗口标准标识）
    /// 信号 2：AXFullScreen 布尔属性 == true（部分应用只暴露此属性）
    /// 注意：kAXFullScreenAttribute 常量在 Swift scope 不存在，属性名用字符串
    private func isWindowFullScreen(_ window: AXUIElement) -> Bool {
        if AXWindowReader.string(window, kAXSubroleAttribute as String) == "AXFullScreenWindow" {
            return true
        }
        if AXWindowReader.bool(window, "AXFullScreen") == true {
            return true
        }
        return false
    }

    /// 触发退出全屏（方案 A：退出后不自动重进——窗口以普通窗口身份被搬回目标屏，
    /// 用户需要全屏时再手动点绿灯）
    /// 全屏窗口在独立 Space，AX kAXPositionAttribute 设置被系统忽略，必须先退出全屏才能移动
    private func triggerExitFullScreen(pid: pid_t, window: AXUIElement, windowID: String) {
        // 防重入：退出全屏动画约 0.5-1s，期间轮询每 100ms 命中一次，3s 冷却内不重复触发
        let fsKey = "fsExit:\(pid)"
        if cooldowns.isCoolingDown(fsKey) { return }
        cooldowns.coolDown(fsKey, duration: 3.0)

        // 首选：直接置 AXFullScreen = false
        var result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        if result != .success {
            // 兜底：部分应用不支持设置 AXFullScreen 属性——按下全屏按钮（绿灯）退出。
            // 仅当按钮 subrole 为 AXFullScreenButton 时按下，避免误触发普通窗口 AXZoomButton 的缩放
            if let button = AXWindowReader.element(window, kAXZoomButtonAttribute as String),
               AXWindowReader.string(button, kAXSubroleAttribute as String) == "AXFullScreenButton" {
                result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        }
        logger.info("triggerExitFullScreen: pid=\(pid, privacy: .public) windowID=\(windowID, privacy: .public) result=\(result.rawValue, privacy: .public)")

        // 退出动画期间加入冷却，避免轮询在动画未完成时反复搬动
        cooldowns.coolDown("move:\(windowID)", duration: 1.5)
    }

    /// 获取屏幕ID
    /// 用 visibleFrame 容差匹配（与 isTargetScreenAvailable 一致），避免 Dock 高度变化后匹配失败
    private func getScreenID(_ screenFrame: CGRect) -> UInt32? {
        for screen in NSScreen.screens {
            if abs(screen.visibleFrame.minX - screenFrame.minX) < Self.screenFrameTolerance
                && abs(screen.visibleFrame.minY - screenFrame.minY) < Self.screenFrameTolerance
                && abs(screen.visibleFrame.width - screenFrame.width) < Self.screenFrameTolerance
                && abs(screen.visibleFrame.height - screenFrame.height) < Self.screenFrameTolerance {
                return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            }
        }
        return nil
    }

    // MARK: - 坐标系转换辅助
    // macOS 存在两套坐标系:
    //   BL (Bottom-Left): NSScreen.frame / NSScreen.visibleFrame / NSEvent.mouseLocation — Y 向上
    //   TL (Top-Left):    AXUIElement kAXPositionAttribute / CGWindowList kCGWindowBounds — Y 向下
    // X 轴两系统相同，只有 Y 需要转换。
    // 转换公式: y_TL = primaryScreenHeight - y_BL
    //   primaryScreenHeight = NSScreen.screens[0].frame.height (主屏幕永远是 screens[0])
    // 多屏安全: 该公式是全局的，对所有屏幕（主屏/副屏）均适用。
    // 无头环境安全: 显示器全拔/远程断开时 NSScreen.screens 可能为空，first 防御防数组越界

    /// 主屏幕高度（BL 坐标系的全局 Y 轴最大值）；无屏时返回 0（调用方跳过搬动判断）
    private var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// 将 BL 坐标系的 Y 值转换为 TL 坐标系
    private func blToTL_Y(_ y_BL: CGFloat) -> CGFloat {
        primaryScreenHeight - y_BL
    }

    /// 将 visibleFrame (BL) 转换为 TL 坐标系
    /// 实现外移至 SwallowScreenCore.ScreenGeometry（纯函数，供单测覆盖），此处仅转发
    private func visibleFrameToTL(_ frame: CGRect) -> CGRect {
        ScreenGeometry.visibleFrameToTL(frame, screenHeight: primaryScreenHeight)
    }

    /// 优先从 AX 读取 size（content 实际尺寸，不含阴影），保证居中计算准确
    /// CGWindowList bounds.size 在不同 macOS 版本/不同应用上可能包含窗口阴影，
    /// 用 AX size 才能保证 content 在 visibleFrame 几何中心。
    /// 仅当 AX size 读取失败（width<=0 或 height<=0）时回退到 fallback（通常是 CG bounds.size）
    private func readWindowSizeFromAX(_ window: AXUIElement, fallback: CGSize? = nil) -> CGSize {
        if let size = AXWindowReader.size(window), size.width > 0, size.height > 0 {
            return size
        }
        return fallback ?? .zero
    }

    /// 将窗口移入目标屏幕——拖到其他屏幕时居中弹回
    /// 用 hideMoveUnhide 而非直接 AX 设置位置：直接设置会被窗口管理器"纠正"（吸附/避遮挡），
    /// 隐藏窗口的移动则不受干扰
    private func moveWindowToTargetScreen(_ window: AXUIElement, screenFrame: CGRect, visibleFrame: CGRect, windowID: String, prebuiltSize: CGSize? = nil) {
        // 回弹期与启动期一致用 hideMoveUnhide；prebuiltSize 作 AX size 失败时的 fallback
        hideMoveUnhide(axWindows: [window], targetFrame: visibleFrame, prebuiltSize: prebuiltSize)

        // 回读窗口实际位置作为缓存（hideMoveUnhide 内部有 clamp，实际位置可能与理论计算不同）
        // expectedPos 用 TL 坐标系（与 AX position 一致）
        let actualSize = readWindowSizeFromAX(window, fallback: prebuiltSize)
        let visibleTL = visibleFrameToTL(visibleFrame)
        let expectedPos = CGPoint(
            x: visibleTL.midX - actualSize.width / 2,
            y: visibleTL.origin.y + (visibleTL.height - actualSize.height) / 2
        )
        var actualPos = expectedPos
        if let readPos = AXWindowReader.position(window) {
            actualPos = readPos
        }
        previousWindowPositions[windowID] = actualPos
        if !previousWindowPositionsOrderSet.contains(windowID) {
            previousWindowPositionsOrder.append(windowID)
            previousWindowPositionsOrderSet.insert(windowID)
        }

        // 延迟验证：500ms 后读取实际位置，偏离中心则再次 hideMoveUnhide
        let windowRef = window
        let windowIDCopy = windowID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.verifyAndRecenterWindow(window: windowRef, visibleFrame: visibleFrame, windowID: windowIDCopy)
        }

        // 冷却 1s，提升连续拖动场景响应
        cooldowns.coolDown("move:\(windowID)", duration: 1.0)

        cooldowns.release("moving:\(windowID)")
    }

    /// 验证窗口是否在 visibleFrame 正中，如果偏离则用 hideMoveUnhide 重新居中
    /// AX 位置使用 TL (Y向下)，visibleFrame 使用 BL (Y向上)，需转换后比较
    private func verifyAndRecenterWindow(window: AXUIElement, visibleFrame: CGRect, windowID: String) {
        guard let currentPos = AXWindowReader.position(window) else { return }

        let useSize = readWindowSizeFromAX(window)
        guard useSize.width > 0, useSize.height > 0 else { return }

        // X 轴两坐标系相同，直接比较；Y 轴需转换
        let visibleTL = visibleFrameToTL(visibleFrame)
        let visibleCenterX = visibleTL.midX
        let visibleCenterY_TL = visibleTL.midY
        let currentCenterX = currentPos.x + useSize.width / 2
        let currentCenterY_TL = currentPos.y + useSize.height / 2

        let isOffCenter = abs(currentCenterX - visibleCenterX) > 5 || abs(currentCenterY_TL - visibleCenterY_TL) > 5

        if isOffCenter {
            logger.warning("verifyAndRecenterWindow: 偏离中心! windowID=\(windowID, privacy: .public) dy=\(currentCenterY_TL - visibleCenterY_TL, privacy: .public) useSize=\(NSStringFromSize(useSize), privacy: .public) currentPos=\(NSStringFromPoint(currentPos), privacy: .public) → recentering")
            hideMoveUnhide(axWindows: [window], targetFrame: visibleFrame, prebuiltSize: useSize)
        }
    }
    
    func moveAppToScreen(bundleIdentifier: String, screenID: UInt32, screenSerialNumber: String?, titlePattern: String? = nil) {
        // 首先尝试通过序列号找到屏幕（统一走 ScreenManager 匹配）
        if let serial = screenSerialNumber {
            if let matchedScreen = screenManager.screen(serialNumber: serial) {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                    let pid = app.processIdentifier
                    // 走 earlyWindowCatcher 链路（hide → move → unhide + 稳态校验）
                    // 用 visibleFrame 居中放置，避免覆盖菜单栏/Dock
                    earlyWindowCatcher(pid: pid, targetFrame: matchedScreen.visibleFrame, titlePattern: titlePattern)
                }
                return
            }
        }

        // 备用：通过 ID 找屏幕（统一走 ScreenManager.screen(id:)）
        guard let screenInfo = screenManager.screen(id: screenID) else { return }

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            let pid = app.processIdentifier
            // 同上：走 earlyWindowCatcher 链路
            earlyWindowCatcher(pid: pid, targetFrame: screenInfo.visibleFrame, titlePattern: titlePattern)
        }
    }

    /// 移动窗口到指定位置（居中）
    /// 坐标系：macOS 左下角原点，Y 轴向上。kAXPositionAttribute = 窗口左下角坐标。
    /// size 获取优先级：prebuiltSize > AX kAXSizeAttribute > CGWindowList bounds.size
    /// - Returns: 新的窗口位置（BL 坐标）；调用方通常不关心结果
    @discardableResult
    private func moveWindowToFrameImmediate(_ window: AXUIElement, targetFrame: CGRect, prebuiltSize: CGSize? = nil) -> CGPoint? {
        // 多层 fallback 获取窗口尺寸：
        // 1. prebuiltSize（调用方传入的 CGWindowList bounds.size，最可靠）
        // 2. AX kAXSizeAttribute（可能返回 0 或不含标题栏的值）
        // 3. CGWindowList 查询（通过 AXUIElementGetPid 获取 pid 后查询）
        var size = readWindowSizeFromAX(window, fallback: prebuiltSize)

        if size.width <= 0 || size.height <= 0 {
            // AX size 失效——通过 pid 查 CGWindowList 获取真实 bounds
            var pid: pid_t = 0
            if AXUIElementGetPid(window, &pid) == .success, pid > 0 {
                if let cgBounds = findOnScreenWindow(for: pid) {
                    size = cgBounds.size
                    logger.info("moveWindowToFrameImmediate: AX size 失效，回退 CGWindowList size=\(NSStringFromSize(size), privacy: .public) pid=\(pid, privacy: .public)")
                }
            }
            if size.width <= 0 || size.height <= 0 {
                logger.error("moveWindowToFrameImmediate: 所有 size 获取方式均失败，放弃居中")
                return nil
            }
        }

        // 坐标系转换: visibleFrame (BL) → TL，与 AX position 同系
        let visibleTL = visibleFrameToTL(targetFrame)

        var newPosition = CGPoint(
            x: targetFrame.origin.x + (targetFrame.width - size.width) / 2,
            y: visibleTL.origin.y + (visibleTL.height - size.height) / 2
        )

        // clamp 确保窗口完全在可见区域内 (TL 坐标系)
        if size.width > targetFrame.width {
            newPosition.x = targetFrame.origin.x
        } else {
            newPosition.x = max(targetFrame.origin.x, min(newPosition.x, targetFrame.maxX - size.width))
        }
        if size.height > targetFrame.height {
            newPosition.y = visibleTL.origin.y
        } else {
            newPosition.y = max(visibleTL.origin.y, min(newPosition.y, visibleTL.maxY - size.height))
        }

        logger.debug("moveWindowToFrameImmediate: targetFrame(BL)=\(NSStringFromRect(targetFrame), privacy: .public) visibleTL=\(NSStringFromRect(visibleTL), privacy: .public) winSize=\(NSStringFromSize(size), privacy: .public) → newPos(TL)=\(NSStringFromPoint(newPosition), privacy: .public)")

        var position = newPosition
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        return newPosition
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
