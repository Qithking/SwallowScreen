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
import os.log

@MainActor
class WindowMover: ObservableObject {
    @Published var isMonitoring: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    
    private var timer: DispatchSourceTimer?
    private var modelContext: ModelContext?
    private var checkInterval: TimeInterval = 0.2  // 固定屏幕检查间隔
    private var lastMovedWindows: Set<String> = [] // 冷却中的窗口
    private var previousWindowPositions: [String: CGPoint] = [:] // 上次窗口位置
    // RT57: 维护并列的插入顺序数组，按索引清理最旧的一半
    private var previousWindowPositionsOrder: [String] = []
    // R-151: 配套的 Set，contains 走 O(1)——替代 Array.contains O(n) 性能问题
    private var previousWindowPositionsOrderSet: Set<String> = []
    private var movingWindows: Set<String> = [] // 正在移动的窗口

    // 观察者 token，用于 deinit 时清理
    private var appLaunchObserverToken: NSObjectProtocol?
    // 冷却清理用的 DispatchWorkItem 缓存，便于 deinit 一并取消
    private var cooldownWorkItems: [String: DispatchWorkItem] = [:]
    // T18: AppInfo 列表指纹，用于"配置未变则跳过"
    private var lastAppsFingerprint: Int = 0
    // RT1: 按 pid 维度持有的检测上下文；新启动同 pid App 会取消旧上下文
    private var activeDetections: [pid_t: DetectionContext] = [:]
    // RT1: 稳态校验每个 pid 独立计数
    private var stabilityCount: [pid_t: Int] = [:]
    // RT14: CG 检测间隔，按屏幕最大帧率动态决定
    private var cgDetectionInterval: TimeInterval {
        // RT48: 取所有屏最大刷新率（避免主屏 60Hz 时漏检 120Hz 副屏）
        let maxFPS = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        return maxFPS >= 120 ? 0.008 : 0.016
    }
    // RT65: 启动期 moveAllOpenAppsToAssignedScreens 的 task 句柄，可取消
    private var moveAllAppsTask: Task<Void, Never>?
    // RT74: 启动期 true，期间 checkAndEnforcePinnedWindows 跳过 pinToScreen 防竞态
    private var isPerformingInitialMove: Bool = false

    init() {
        _ = checkAccessibilityPermission()
        setupAppLaunchObserver()
    }

    deinit {
        // RT149: 显式 cancel 顶层 dispatch timer；之前漏 cancel 导致 ARC 释放时
        //        dispatch source 仍持引用直到 timer 触发或手动 cancel
        self.timer?.cancel()
        if let token = appLaunchObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        for context in activeDetections.values { context.cancel() }
        for item in cooldownWorkItems.values { item.cancel() }
    }
    
    /// 设置应用启动观察者
    /// RT17: [weak self] 写在 Task 闭包内（Swift 捕获列表必须在闭包起始位置）
    private func setupAppLaunchObserver() {
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
    /// RT12: 用两步过滤避免 SwiftData #Predicate 对 optional 字段的兼容问题
    /// RT66: hasTarget 包含 targetScreenName，与 moveAllOpenAppsToAssignedScreens / checkAndEnforcePinnedWindows 对齐
    private func handleAppLaunch(bundleIdentifier: String, pid: pid_t) {
        guard let modelContext = modelContext else { return }

        // RT12: 先用 isEnabled == true 谓词拉全部启用的配置（避免在 predicate 中引用 optional 字段）
        let enabledDescriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true }
        )
        guard let enabledApps = try? modelContext.fetch(enabledDescriptor) else { return }
        guard let appInfo = enabledApps.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }

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
            os_log("未找到 App 配置的目标屏幕: bundleID=%{public}@ targetScreenID=%{public}@ targetScreenSerialNumber=%{public}@ targetScreenName=%{public}@",
                   log: OSLog.default, type: .error,
                   bundleIdentifier,
                   String(describing: appInfo.targetScreenID),
                   appInfo.targetScreenSerialNumber ?? "<nil>",
                   appInfo.targetScreenName ?? "<nil>")
            return
        }

        // 早期窗口检测 + 移动 + 稳态校验（CGWindowList 16ms + AX 100ms 双链）
        earlyWindowCatcher(pid: pid, targetFrame: resolved.frame)
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
    private func hideMoveUnhide(axWindows: [AXUIElement], targetFrame: CGRect) {
        // 1) 仅对"还活着"的窗口走 hide 路径，已销毁的窗口直接跳过
        let alive: [AXUIElement] = axWindows.filter { isAXWindowAlive($0) }
        for window in alive { setAXWindowHidden(window, hidden: true) }
        for window in alive { moveWindowToFrameImmediate(window, targetFrame: targetFrame) }
        for window in alive {
            if !setAXWindowHidden(window, hidden: false) {
                let key = cooldownKey(axWindow: window)
                // RT5: 覆盖前先取消旧 workItem，避免旧的不必要的执行
                cooldownWorkItems[key]?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.setAXWindowHidden(window, hidden: false)
                    // RT5: unhide retry 自清理 dict
                    self?.cooldownWorkItems.removeValue(forKey: key)
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
    private func findOnScreenWindow(for pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
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
    private func earlyWindowCatcher(pid: pid_t, targetFrame: CGRect) {
        // 同 pid 已有上下文在跑 → 取消旧上下文（用户重启 App 的场景）
        if let existing = activeDetections[pid] {
            existing.cancel()
            activeDetections.removeValue(forKey: pid)
        }
        // RT103: 抓取 launchDate 用于 PID 复用防御
        let launchDate = NSRunningApplication(processIdentifier: pid)?.launchDate
        let detectionTimeout: TimeInterval = 5.0
        let context = DetectionContext(pid: pid, targetFrame: targetFrame, launchDate: launchDate)
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
    /// R-150: matchAXWindow 拿不到时 silent return + os_log——避免误搬 IDE 等多窗口 App
    ///        的辅助窗口（Navigator/Inspector/Outline），不再回退搬动所有 AX 窗口
    private func onWindowDetected(pid: pid_t, targetFrame: CGRect, initialBounds: CGRect) {
        // R-127: PID 复用防御——context 仍在 activeDetections（stopDetectionTimers 未删除）
        if let context = activeDetections[pid], !context.isPIDStillOriginal() {
            os_log("onWindowDetected(CG) PID 已被复用: pid=%d, 放弃搬动", log: OSLog.default, type: .error, pid)
            cancelDetectionContext(pid: pid)
            return
        }

        // 用 CG bounds 去 AX 列表里匹配同一个窗口
        if let axWindow = matchAXWindow(for: pid, targetBounds: initialBounds) {
            // hide → move → unhide，让用户看不到"错误屏幕位置"那一两帧
            hideMoveUnhide(axWindows: [axWindow], targetFrame: targetFrame)
        } else {
            // R-150: AX 拿不到这个具体窗口时 silent return——多窗口 App 的其他窗口
            //        不应被批量搬动到 targetFrame 中心点导致重叠
            os_log("onWindowDetected(CG) matchAXWindow 失败: pid=%d initialBounds=%{public}@, 放弃搬动",
                   log: OSLog.default, type: .error, pid, NSStringFromRect(initialBounds))
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
    private func onWindowDetected(pid: pid_t, targetFrame: CGRect, axWindows: [AXUIElement]) {
        if let context = activeDetections[pid], !context.isPIDStillOriginal() {
            os_log("onWindowDetected(AX) PID 已被复用: pid=%d, 放弃搬动", log: OSLog.default, type: .error, pid)
            cancelDetectionContext(pid: pid)
            return
        }

        // R-186: 挑主窗口——优先有 title 的（IDE 主窗口/Safari 标签等），否则挑面积最大的
        if let mainWindow = pickMainWindow(from: axWindows) {
            hideMoveUnhide(axWindows: [mainWindow], targetFrame: targetFrame)
        } else {
            os_log("onWindowDetected(AX) 挑不出主窗口: pid=%d windowsCount=%d, 放弃搬动",
                   log: OSLog.default, type: .error, pid, axWindows.count)
        }

        // RT2: 延迟 120ms 让 unhide 重试先完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
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
                // R-184: matchAXWindow 拿不到时 silent return——避免多窗口 App（IDE）误搬辅助窗口
                if let bounds = currentBounds,
                   let axWindow = self.matchAXWindow(for: pid, targetBounds: bounds) {
                    self.hideMoveUnhide(axWindows: [axWindow], targetFrame: targetFrame)
                } else {
                    // R-184: 拿不到具体窗口时 silent return，不再回退搬动所有 AX 窗口或调老路径
                    os_log("startStabilityCheck 回弹: matchAXWindow 失败: pid=%d, 放弃重新搬动",
                           log: OSLog.default, type: .error, pid)
                }
            }
        }
        context.stabilityTimer = timer
        timer.resume()
    }

    /// 判断窗口是否"在目标屏"：中心点 OR 50% 面积在 visibleFrame 内
    /// RT4: 替换旧的"仅看中心点"判定；同时返回 overlap ratio 用于更细粒度判断
    private func isBoundsInTargetFrame(_ bounds: CGRect, targetFrame: CGRect) -> Bool {
        // 中心点命中
        let centerX = bounds.origin.x + bounds.width / 2
        let centerY = bounds.origin.y + bounds.height / 2
        if targetFrame.contains(CGPoint(x: centerX, y: centerY)) {
            return true
        }
        // 50% 面积命中（处理超大多窗口/跨屏窗口场景）
        if windowOverlapRatio(bounds, targetFrame: targetFrame) >= 0.5 {
            return true
        }
        return false
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

        // RT147: 入口完整状态重置，保证幂等（防止 stopMonitoring 中途失败时状态不一致）
        lastAppsFingerprint = 0
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
    private func moveAllOpenAppsToAssignedScreens() async {
        guard let modelContext = modelContext else { return }

        if !AXIsProcessTrusted() {
            return
        }

        // R-190: 谓词化——只拉启用 App，与 R-152 checkAndEnforcePinnedWindows 风格一致
        //        for 循环 line 678 guard appInfo.isEnabled 仍保留作防御（SwiftData 谓词不强制收紧）
        // R-214: FetchDescriptor 加 sortBy: \.bundleIdentifier——保证 fetch 顺序稳定
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.bundleIdentifier)]
        )
        guard let allApps = try? modelContext.fetch(descriptor) else { return }

        // RT53: 每批最多启动 5 个 earlyWindowCatcher 后让出主 RunLoop，
        // 防止 N 个 app 配 N*3 个 DispatchSourceTimer 瞬时 fan-out
        let batchSize = 5
        var processedInBatch = 0

        for appInfo in allApps {
            // 只有启用状态且设置了目标屏幕才处理
            guard appInfo.isEnabled else { continue }
            guard appInfo.targetScreenID != nil || appInfo.targetScreenSerialNumber != nil || appInfo.targetScreenName != nil else { continue }

            // RT73: 每个 app 重新读 currentScreens
            let currentScreens = getCurrentScreenMappings()

            // RT69: 走 resolveTargetFrame helper
            guard let resolved = resolveTargetFrame(for: appInfo, currentScreens: currentScreens) else {
                // RT31: 同上，moveAllOpenAppsToAssignedScreens 路径也要打日志
                os_log("未找到 App 配置的目标屏幕（启动时）: bundleID=%{public}@ targetScreenID=%{public}@ targetScreenSerialNumber=%{public}@ targetScreenName=%{public}@",
                       log: OSLog.default, type: .error,
                       appInfo.bundleIdentifier,
                       String(describing: appInfo.targetScreenID),
                       appInfo.targetScreenSerialNumber ?? "<nil>",
                       appInfo.targetScreenName ?? "<nil>")
                continue
            }

            // 找到运行中的应用并移动（走与 handleAppLaunch 相同的早期检测入口）
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appInfo.bundleIdentifier).first {
                let pid = app.processIdentifier
                earlyWindowCatcher(pid: pid, targetFrame: resolved.frame)
                processedInBatch += 1
                if processedInBatch >= batchSize {
                    processedInBatch = 0
                    // RT53: 让出主 RunLoop，避免 detection timer 全部堆积
                    await Task.yield()
                }
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
        lastAppsFingerprint = 0
    }
    
    /// 检查并强制执行固定屏幕规则
    /// T18: 用 AppInfo 列表的"指纹"做短路，未变化时直接跳过 fetch 后逻辑
    /// RT74: 启动期 isPerformingInitialMove=true 时跳过 pinToScreen 路径，避免与
    ///       moveAllOpenAppsToAssignedScreens 竞争 activeDetections
    private func checkAndEnforcePinnedWindows() {
        guard let modelContext = modelContext else { return }

        if !AXIsProcessTrusted() {
            if hasAccessibilityPermission {
                hasAccessibilityPermission = false
            }
            return
        }
        hasAccessibilityPermission = true

        // R-152: 用 isEnabled == true 谓词只拉启用 App——避免 SwiftData 拉全表后 .filter 的不必要数据传输
        // R-214: FetchDescriptor 加 sortBy: \.bundleIdentifier——保证 fetch 顺序稳定，computeAppsFingerprint 不因顺序漂移而误判
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.bundleIdentifier)]
        )
        guard let allApps = try? modelContext.fetch(descriptor) else { return }

        // RT46: 每次 check 末尾清理无界增长的窗口字典
        trimWindowDictionariesIfNeeded()

        // RT74: 启动期内跳过 pinToScreen 检查，避免与 moveAllOpenAppsToAssignedScreens 竞态
        if isPerformingInitialMove { return }

        // T18: 指纹 = 启用的 app 数量 + 标识 + 关键配置（id, pinToScreen, targetScreenID, targetScreenSerialNumber）
        // R-215: 指纹只用于"配置变更感知"——配置未变时也要执行下方的 checkWindowPosition 循环
        //        因为窗口位置变化（用户拖拽）不改变 fingerprint，但 pinToScreen 持续执行需要 position 校验
        //        修复前：fingerprint 不变 → 早返回 → 用户拖开 pinned 窗口永远不被纠回（核心功能破坏）
        let fingerprint = computeAppsFingerprint(allApps)
        if fingerprint != lastAppsFingerprint {
            lastAppsFingerprint = fingerprint
        }

        // 获取当前所有屏幕信息
        let currentScreens = getCurrentScreenMappings()

        for appInfo in allApps {
            // 只有启用状态才处理
            guard appInfo.isEnabled else { continue }

            // RT69: 走 resolveTargetFrame helper
            guard let resolved = resolveTargetFrame(for: appInfo, currentScreens: currentScreens) else {
                continue
            }

            // 找到运行中的应用
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appInfo.bundleIdentifier).first else {
                continue
            }

            let pid = app.processIdentifier

            if appInfo.pinToScreen {
                // 固定屏幕模式：窗口不能移动到其他屏幕
                checkWindowPosition(pid: pid, targetFrame: resolved.frame, appBundleID: appInfo.bundleIdentifier, screenID: resolved.id)
            }
            // 注意：只有 pinToScreen = true 时才持续限制窗口
            // 普通设置目标屏幕的应用，只在应用启动时移动一次，之后允许自由移动
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
            os_log("previousWindowPositions 触发清理: 移除 %d 条，剩余 %d",
                   log: OSLog.default, type: .debug, removeCount, previousWindowPositions.count)
        }
        if movingWindows.count > Self.windowDictionaryMaxCount {
            let removeCount = Self.windowDictionaryMaxCount / 2
            let snapshot = Array(movingWindows)
            for id in snapshot.prefix(removeCount) {
                movingWindows.remove(id)
            }
            os_log("movingWindows 触发清理: 移除 %d 条，剩余 %d",
                   log: OSLog.default, type: .debug, removeCount, movingWindows.count)
        }
    }
    
    /// 屏幕信息结构（RT54: 与 ScreenManager.ScreenInfo 字段基本一致；保留本地 struct 以避免 isMain 字段强制传递）
    private struct ScreenInfo {
        let id: UInt32
        let name: String
        let frame: CGRect
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

        init(pid: pid_t, targetFrame: CGRect, launchDate: Date? = nil) {
            self.pid = pid
            self.targetFrame = targetFrame
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
    
    /// 获取当前屏幕映射
    /// RT54 注: ScreenManager 是 @MainActor 实例类，无 shared；本方法保留为本地实现，但与 ScreenManager.screens 字段结构保持一致
    private func getCurrentScreenMappings() -> [ScreenInfo] {
        var mappings: [ScreenInfo] = []
        for screen in NSScreen.screens {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let name = screen.localizedName
            // 使用 visibleFrame 获取可视区域（排除菜单栏和 Dock），确保窗口在可视区域内居中
            let frame = screen.visibleFrame
            let serialNumber = ScreenManager.serialNumber(for: screen)
            mappings.append(ScreenInfo(id: screenID, name: name, frame: frame, serialNumber: serialNumber))
        }
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
        os_log("findScreenBySerialNumber 未匹配: 输入=%{public}@ 候选=[%{public}@]",
               log: OSLog.default, type: .debug, serial, candidates)
        return nil
    }

    /// 通过名称查找屏幕 frame
    private func findScreenFrameByName(_ name: String, currentScreens: [ScreenInfo]) -> CGRect? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }

        // RT6: 仅做精确匹配 + 标准化匹配（trim + caseInsensitive）
        if let exact = currentScreens.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            return exact.frame
        }
        // RT42: 匹配失败时输出 debug 日志
        let candidates = currentScreens.map { $0.name }.joined(separator: " | ")
        os_log("findScreenFrameByName 未匹配: 输入=%{public}@ 候选=[%{public}@]",
               log: OSLog.default, type: .debug, normalizedName, candidates)
        return nil
    }

    /// RT69: 抽 resolveTargetFrame helper
    /// 三处调用点（handleAppLaunch / moveAllOpenAppsToAssignedScreens / checkAndEnforcePinnedWindows）统一
    /// 优先级：serialNumber → screenID → screenName
    /// - Returns: (frame, id) 元组；id 仅 checkAndEnforcePinnedWindows 需要
    private func resolveTargetFrame(for appInfo: AppInfo, currentScreens: [ScreenInfo]) -> (frame: CGRect, id: UInt32)? {
        if let serialNumber = appInfo.targetScreenSerialNumber,
           let matched = findScreenBySerialNumber(serialNumber, currentScreens: currentScreens) {
            return (matched.frame, matched.id)
        }
        if let screenID = appInfo.targetScreenID,
           let frame = getScreenFrame(for: screenID) {
            return (frame, screenID)
        }
        if let screenName = appInfo.targetScreenName,
           let frame = findScreenFrameByName(screenName, currentScreens: currentScreens) {
            // 名称匹配时，尝试找到对应的 ID
            let id = currentScreens.first(where: { $0.frame == frame })?.id ?? 0
            return (frame, id)
        }
        return nil
    }
    
    /// 检查窗口位置并处理
    /// RT4: 鼠标位置不再作为唯一跳过条件；主判定改为"窗口中心点 OR 50% 面积在目标屏 visibleFrame 内"
    private func checkWindowPosition(pid: pid_t, targetFrame: CGRect, appBundleID: String, screenID: UInt32) {
        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return
        }

        for window in windows {
            var positionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
                  let posVal = positionValue else {
                continue
            }

            var axPosition = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &axPosition)

            // R-182: windowID 改用位置-based key——AXUIElement 每次 AXUIElementCopyAttributeValue(kAXWindowsAttribute)
            //        都创建新 wrapper 对象，hashValue / ObjectIdentifier 跨调用不稳定，
            //        导致 lastMovedWindows 5s 冷却完全失效。
            //        用位置拼 key——同位置稳定（同一次/不同次 check 都不变），5s 冷却跨调用稳定生效
            let windowID = "\(pid)-\(Int(axPosition.x))-\(Int(axPosition.y))"

            // 如果窗口位置变化很小，跳过（使用容差处理浮点数精度问题）
            if let prev = previousWindowPositions[windowID],
               abs(prev.x - axPosition.x) < 1.0 && abs(prev.y - axPosition.y) < 1.0 {
                continue
            }

            previousWindowPositions[windowID] = axPosition
            // R-151: 用 Set.contains O(1) 替代 Array.contains O(n)——窗口数 × 字典大小时性能差异显著
            // RT57: 同步记录插入顺序
            if !previousWindowPositionsOrderSet.contains(windowID) {
                previousWindowPositionsOrder.append(windowID)
                previousWindowPositionsOrderSet.insert(windowID)
            }

            // RT4: 5s 冷却（用户用快捷键主动挪到目标屏后，鼠标经过目标屏不应立即触发回拉）
            if lastMovedWindows.contains(windowID) {
                continue
            }

            // 如果已经在移动中，跳过
            if movingWindows.contains(windowID) {
                continue
            }

            // RT4 + RT69: 主判定——窗口是否"在目标屏"（mouseScreen 死注释已删除）
            let currentBounds: CGRect
            if let sizeVal = copySize(window) {
                currentBounds = CGRect(origin: axPosition, size: sizeVal)
            } else {
                currentBounds = CGRect(origin: axPosition, size: .zero)
            }
            if isBoundsInTargetFrame(currentBounds, targetFrame: targetFrame) {
                continue
            }

            // 窗口不在目标屏，移回目标屏幕
            movingWindows.insert(windowID)
            moveWindowToScreenCenter(window, targetFrame: targetFrame, windowID: windowID)
        }
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
    
    /// 将窗口移到屏幕中心
    private func moveWindowToScreenCenter(_ window: AXUIElement, targetFrame: CGRect, windowID: String) {
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)

        var size = CGSize.zero
        if let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }

        // 计算窗口中心位置（使用完整的目标屏幕坐标）
        let newPosition = CGPoint(
            x: targetFrame.origin.x + (targetFrame.width - size.width) / 2,
            y: targetFrame.origin.y + (targetFrame.height - size.height) / 2
        )

        var position = newPosition
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            if result == .success {
                lastMovedWindows.insert(windowID)
                movingWindows.remove(windowID)

                // RT4: 5s 冷却（与 RT4 主判定匹配——5s 内不重复触发）
                let key = cooldownKey(windowID: windowID)
                // RT5: 覆盖前先 cancel 旧 workItem，避免"新加入的窗口被旧 workItem 提前移出冷却"
                cooldownWorkItems[key]?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.lastMovedWindows.remove(windowID)
                    self?.cooldownWorkItems.removeValue(forKey: key)
                }
                cooldownWorkItems[key] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
            } else {
                // 移动失败时也要清理 movingWindows，避免窗口被永久阻塞
                movingWindows.remove(windowID)
            }
        } else {
            // 创建位置值失败时也要清理 movingWindows
            movingWindows.remove(windowID)
        }
    }
    
    private func getScreenFrame(for displayID: UInt32) -> CGRect? {
        for screen in NSScreen.screens {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if screenID == displayID {
                // 使用 visibleFrame 返回可视区域（排除菜单栏和 Dock），确保窗口在可视区域内居中
                return screen.visibleFrame
            }
        }
        return nil
    }
    
    func moveAppToScreen(bundleIdentifier: String, screenID: UInt32, screenSerialNumber: String?) {
        // 首先尝试通过序列号找到屏幕
        if let serial = screenSerialNumber {
            if let matchedScreen = findScreenBySerialNumber(serial, currentScreens: getCurrentScreenMappings()) {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                    let pid = app.processIdentifier
                    // RT67: 走 earlyWindowCatcher 链路（hide → move → unhide + 稳态校验 + 防回弹）
                    earlyWindowCatcher(pid: pid, targetFrame: matchedScreen.frame)
                }
                return
            }
        }

        // 备用：通过 ID 找屏幕
        guard let screenFrame = getScreenFrame(for: screenID) else { return }

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            let pid = app.processIdentifier
            // RT67: 同上
            earlyWindowCatcher(pid: pid, targetFrame: screenFrame)
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
        
        let newPosition = CGPoint(
            x: targetFrame.origin.x + (targetFrame.width - size.width) / 2,
            y: targetFrame.origin.y + (targetFrame.height - size.height) / 2
        )
        
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
        checkAndEnforcePinnedWindows()
    }
}
