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

@MainActor
class WindowMover: ObservableObject {
    @Published var isMonitoring: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    
    private var timer: Timer?
    private var modelContext: ModelContext?
    private var checkInterval: TimeInterval = 0.2  // 固定屏幕检查间隔
    private var lastMovedWindows: Set<String> = [] // 冷却中的窗口
    private var previousWindowPositions: [String: CGPoint] = [:] // 上次窗口位置
    private var movingWindows: Set<String> = [] // 正在移动的窗口
    
    init() {
        _ = checkAccessibilityPermission()
        setupAppLaunchObserver()
    }
    
    /// 设置应用启动观察者
    private func setupAppLaunchObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                self?.handleAppLaunch(bundleIdentifier: bundleID, pid: pid)
            }
        }
    }
    
    /// 处理应用启动
    private func handleAppLaunch(bundleIdentifier: String, pid: pid_t) {
        guard let modelContext = modelContext else { return }
        
        // 查询应用配置
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.bundleIdentifier == bundleIdentifier && $0.isEnabled == true }
        )
        
        guard let appInfo = try? modelContext.fetch(descriptor).first else { return }
        
        // 如果设置了目标屏幕且没有启用固定屏幕
        if appInfo.targetScreenID != nil || appInfo.targetScreenSerialNumber != nil {
            // 获取当前屏幕信息
            let currentScreens = getCurrentScreenMappings()
            
            // 尝试多种方式匹配屏幕
            var targetFrame: CGRect? = nil
            
            // 1. 首先尝试通过序列号匹配（最可靠）
            if let serialNumber = appInfo.targetScreenSerialNumber {
                if let matchedScreen = findScreenBySerialNumber(serialNumber, currentScreens: currentScreens) {
                    targetFrame = matchedScreen.frame
                }
            }
            
            // 2. 如果序列号匹配失败，尝试通过原始 ID 匹配
            if targetFrame == nil, let screenID = appInfo.targetScreenID {
                targetFrame = getScreenFrame(for: screenID)
            }
            
            // 3. 如果 ID 匹配失败，尝试通过名称匹配
            if targetFrame == nil, let screenName = appInfo.targetScreenName {
                targetFrame = findScreenFrameByName(screenName, currentScreens: currentScreens)
            }
            
            guard let finalTargetFrame = targetFrame else { return }
            
            // 早期窗口检测 + 移动 + 稳态校验（CGWindowList 16ms + AX 100ms 双链）
            earlyWindowCatcher(pid: pid, targetFrame: finalTargetFrame)
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
    private func hideMoveUnhide(axWindows: [AXUIElement], targetFrame: CGRect) {
        for window in axWindows { setAXWindowHidden(window, hidden: true) }
        for window in axWindows { moveWindowToFrameImmediate(window, targetFrame: targetFrame) }
        for window in axWindows {
            if !setAXWindowHidden(window, hidden: false) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.setAXWindowHidden(window, hidden: false)
                }
            }
        }
    }

    /// 通过 CGWindowList 查找指定 PID 的第一个"普通 on-screen"窗口 bounds
    /// 过滤条件：ownerPID 匹配 + layer == 0（普通窗口，过滤菜单栏/系统浮层）+ bounds 非空
    private func findOnScreenWindow(for pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }
            // 仅普通窗口（layer 0 为普通窗口，浮层/菜单栏是更高 layer）
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            // bounds 字段以 CFDictionary 形式给出 {X, Y, Width, Height}
            if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
               let x = boundsDict["X"] as? CGFloat,
               let y = boundsDict["Y"] as? CGFloat,
               let width = boundsDict["Width"] as? CGFloat,
               let height = boundsDict["Height"] as? CGFloat,
               width > 0, height > 0 {
                return CGRect(x: x, y: y, width: width, height: height)
            }
        }
        return nil
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
    private func earlyWindowCatcher(pid: pid_t, targetFrame: CGRect) {
        let detectionTimeout: TimeInterval = 5.0
        // 共享停止标记：任一链命中后，另一链下一轮自检就会退出
        let stopFlag = AtomicFlag()

        // 链 A：CGWindowList 16ms 高频轮询
        DispatchQueue.main.async { [weak self] in
            self?.runCGDetectionLoop(pid: pid, targetFrame: targetFrame, stopFlag: stopFlag, timeout: detectionTimeout)
        }
        // 链 B：AX 100ms 兜底（无 Screen Recording 权限时仍能工作）
        DispatchQueue.main.async { [weak self] in
            self?.runAXDetectionLoop(pid: pid, targetFrame: targetFrame, stopFlag: stopFlag, timeout: detectionTimeout)
        }
    }

    /// 链 A：CGWindowList 16ms 高频轮询
    private func runCGDetectionLoop(pid: pid_t, targetFrame: CGRect, stopFlag: AtomicFlag, timeout: TimeInterval) {
        let startTime = Date()
        let interval: TimeInterval = 0.016  // 16ms

        func tick() {
            if stopFlag.isSet { return }
            if Date().timeIntervalSince(startTime) > timeout { return }
            guard NSRunningApplication(processIdentifier: pid) != nil else { return }

            if let bounds = findOnScreenWindow(for: pid) {
                if stopFlag.trySet() {
                    DispatchQueue.main.async { [weak self] in
                        self?.onWindowDetected(pid: pid, targetFrame: targetFrame, initialBounds: bounds)
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.runCGDetectionLoop(pid: pid, targetFrame: targetFrame, stopFlag: stopFlag, timeout: timeout)
            }
        }
        tick()
    }

    /// 链 B：AX 100ms 兜底轮询
    private func runAXDetectionLoop(pid: pid_t, targetFrame: CGRect, stopFlag: AtomicFlag, timeout: TimeInterval) {
        let startTime = Date()
        let interval: TimeInterval = 0.1  // 100ms

        func tick() {
            if stopFlag.isSet { return }
            if Date().timeIntervalSince(startTime) > timeout { return }
            guard NSRunningApplication(processIdentifier: pid) != nil else { return }

            let appElement = AXUIElementCreateApplication(pid)
            var windowsValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

            if result == .success, let windows = windowsValue as? [AXUIElement], !windows.isEmpty {
                if stopFlag.trySet() {
                    DispatchQueue.main.async { [weak self] in
                        self?.onWindowDetected(pid: pid, targetFrame: targetFrame, axWindows: windows)
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.runAXDetectionLoop(pid: pid, targetFrame: targetFrame, stopFlag: stopFlag, timeout: timeout)
            }
        }
        tick()
    }

    /// 窗口被检测到（CG 链命中）：用 bounds 匹配 AXUIElement，再移动
    private func onWindowDetected(pid: pid_t, targetFrame: CGRect, initialBounds: CGRect) {
        guard NSRunningApplication(processIdentifier: pid) != nil else { return }

        // 用 CG bounds 去 AX 列表里匹配同一个窗口
        if let axWindow = matchAXWindow(for: pid, targetBounds: initialBounds) {
            // hide → move → unhide，让用户看不到"错误屏幕位置"那一两帧
            hideMoveUnhide(axWindows: [axWindow], targetFrame: targetFrame)
        } else {
            // AX 拿不到这个窗口（罕见），回退到直接搬 AX 列表里所有窗口
            let appElement = AXUIElementCreateApplication(pid)
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let axWindows = windowsValue as? [AXUIElement] {
                hideMoveUnhide(axWindows: axWindows, targetFrame: targetFrame)
            }
        }

        // 1 帧延迟后再进入稳态校验，避免"移动刚发出还没生效"导致的无谓二次移动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
        }
    }

    /// 窗口被检测到（AX 链命中）：直接遍历所有 AX 窗口并移动
    private func onWindowDetected(pid: pid_t, targetFrame: CGRect, axWindows: [AXUIElement]) {
        guard NSRunningApplication(processIdentifier: pid) != nil else { return }
        // hide → move → unhide（兜底路径没有具体目标，对全部窗口整体隐藏至 move 完成）
        hideMoveUnhide(axWindows: axWindows, targetFrame: targetFrame)

        // 1 帧延迟后再进入稳态校验
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.startStabilityCheck(pid: pid, targetFrame: targetFrame)
        }
    }

    /// 稳态校验：1.5-2s 内每 100ms 检查一次，发现回弹立刻再搬，连续 3 次稳定停止
    private func startStabilityCheck(pid: pid_t, targetFrame: CGRect) {
        runStabilityTick(pid: pid, targetFrame: targetFrame,
                         startTime: Date(), stableCount: 0)
    }

    /// 稳态校验单次 tick：取出当前窗口 bounds → 判断稳定 → 必要时重新搬
    private func runStabilityTick(pid: pid_t, targetFrame: CGRect,
                                  startTime: Date, stableCount: Int) {
        let checkInterval: TimeInterval = 0.1
        let maxDuration: TimeInterval = 2.0
        let requiredStableCount = 3

        guard NSRunningApplication(processIdentifier: pid) != nil else { return }
        if Date().timeIntervalSince(startTime) > maxDuration { return }

        let currentBounds = findOnScreenWindow(for: pid)
        let isStable = currentBounds.map { isBoundsInTargetFrame($0, targetFrame: targetFrame) } ?? false

        if isStable {
            let newCount = stableCount + 1
            if newCount >= requiredStableCount { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + checkInterval) { [weak self] in
                self?.runStabilityTick(pid: pid, targetFrame: targetFrame,
                                       startTime: startTime, stableCount: newCount)
            }
        } else {
            // 回弹：重新搬（hide → move → unhide，与初始搬动保持一致，避免窗口在两屏间反复闪烁）
            if let bounds = currentBounds,
               let axWindow = matchAXWindow(for: pid, targetBounds: bounds) {
                hideMoveUnhide(axWindows: [axWindow], targetFrame: targetFrame)
            } else {
                // AX 拿不到该窗口，回退到搬所有窗口
                let appElement = AXUIElementCreateApplication(pid)
                var windowsValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                   let axWindows = windowsValue as? [AXUIElement] {
                    hideMoveUnhide(axWindows: axWindows, targetFrame: targetFrame)
                } else {
                    moveAppWindowsToScreen(pid: pid, targetFrame: targetFrame)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + checkInterval) { [weak self] in
                self?.runStabilityTick(pid: pid, targetFrame: targetFrame,
                                       startTime: startTime, stableCount: 0)
            }
        }
    }

    /// 判断窗口 bounds 的中心点是否在目标屏幕的可视区域内
    private func isBoundsInTargetFrame(_ bounds: CGRect, targetFrame: CGRect) -> Bool {
        let centerX = bounds.origin.x + bounds.width / 2
        let centerY = bounds.origin.y + bounds.height / 2
        return targetFrame.contains(CGPoint(x: centerX, y: centerY))
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
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 应用启动时立即执行一次检查，将所有已打开应用移动到指定屏幕
            Task { @MainActor in
                self.moveAllOpenAppsToAssignedScreens()
            }
            
            self.timer = Timer.scheduledTimer(withTimeInterval: self.checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkAndEnforcePinnedWindows()
                }
            }
            RunLoop.current.add(self.timer!, forMode: .common)
        }
        return true
    }
    
    /// 应用启动时移动所有已打开应用到指定屏幕
    private func moveAllOpenAppsToAssignedScreens() {
        guard let modelContext = modelContext else { return }
        
        if !AXIsProcessTrusted() {
            return
        }
        
        do {
            let descriptor = FetchDescriptor<AppInfo>()
            let allApps = try modelContext.fetch(descriptor)
            
            // 获取当前所有屏幕信息
            let currentScreens = getCurrentScreenMappings()
            
            for appInfo in allApps {
                // 只有启用状态且设置了目标屏幕才处理
                guard appInfo.isEnabled else { continue }
                guard appInfo.targetScreenID != nil || appInfo.targetScreenSerialNumber != nil else { continue }
                
                // 尝试通过多种方式匹配屏幕
                var targetScreenFrame: CGRect? = nil
                
                // 1. 首先尝试通过序列号匹配（最可靠）
                if let serialNumber = appInfo.targetScreenSerialNumber {
                    if let matchedScreen = findScreenBySerialNumber(serialNumber, currentScreens: currentScreens) {
                        targetScreenFrame = matchedScreen.frame
                    }
                }
                
                // 2. 如果序列号匹配失败，尝试通过原始 ID 匹配
                if targetScreenFrame == nil, let screenID = appInfo.targetScreenID {
                    targetScreenFrame = getScreenFrame(for: screenID)
                }
                
                // 3. 如果 ID 匹配失败，尝试通过名称匹配
                if targetScreenFrame == nil, let screenName = appInfo.targetScreenName {
                    targetScreenFrame = findScreenFrameByName(screenName, currentScreens: currentScreens)
                }
                
                guard let finalTargetFrame = targetScreenFrame else { continue }
                
                // 找到运行中的应用并移动
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appInfo.bundleIdentifier).first {
                    let pid = app.processIdentifier
                    moveAppWindowsToScreen(pid: pid, targetFrame: finalTargetFrame)
                }
            }
        } catch {
            // 静默处理错误
        }
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        lastMovedWindows.removeAll()
        previousWindowPositions.removeAll()
        movingWindows.removeAll()
    }
    
    /// 检查并强制执行固定屏幕规则
    private func checkAndEnforcePinnedWindows() {
        guard let modelContext = modelContext else { return }
        
        if !AXIsProcessTrusted() {
            if hasAccessibilityPermission {
                hasAccessibilityPermission = false
            }
            return
        }
        hasAccessibilityPermission = true
        
        do {
            let descriptor = FetchDescriptor<AppInfo>()
            let allApps = try modelContext.fetch(descriptor)
            
            // 获取当前所有屏幕信息
            let currentScreens = getCurrentScreenMappings()
            
            for appInfo in allApps {
                // 只有启用状态才处理
                guard appInfo.isEnabled else { continue }
                
                // 尝试通过多种方式匹配屏幕
                var targetScreenFrame: CGRect? = nil
                var targetScreenID: UInt32? = nil
                
                // 1. 首先尝试通过序列号匹配（最可靠）
                if let serialNumber = appInfo.targetScreenSerialNumber {
                    if let matchedScreen = findScreenBySerialNumber(serialNumber, currentScreens: currentScreens) {
                        targetScreenFrame = matchedScreen.frame
                        targetScreenID = matchedScreen.id
                    }
                }
                
                // 2. 如果序列号匹配失败，尝试通过原始 ID 匹配
                if targetScreenFrame == nil, let screenID = appInfo.targetScreenID {
                    targetScreenID = screenID
                    targetScreenFrame = getScreenFrame(for: screenID)
                }
                
                // 3. 如果 ID 匹配失败，尝试通过名称匹配
                if targetScreenFrame == nil, let screenName = appInfo.targetScreenName {
                    targetScreenFrame = findScreenFrameByName(screenName, currentScreens: currentScreens)
                    // 名称匹配时，尝试找到对应的 ID
                    if let frame = targetScreenFrame {
                        if let matched = currentScreens.first(where: { $0.frame == frame }) {
                            targetScreenID = matched.id
                        }
                    }
                }
                
                guard let finalTargetFrame = targetScreenFrame,
                      let finalScreenID = targetScreenID else { continue }
                
                // 找到运行中的应用
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: appInfo.bundleIdentifier).first else {
                    continue
                }
                
                let pid = app.processIdentifier
                
                if appInfo.pinToScreen {
                    // 固定屏幕模式：窗口不能移动到其他屏幕
                    checkWindowPosition(pid: pid, targetFrame: finalTargetFrame, appBundleID: appInfo.bundleIdentifier, screenID: finalScreenID)
                }
                // 注意：只有 pinToScreen = true 时才持续限制窗口
                // 普通设置目标屏幕的应用，只在应用启动时移动一次，之后允许自由移动
            }
        } catch {
            // 静默处理错误
        }
    }
    
    /// 屏幕信息结构
    private struct ScreenInfo {
        let id: UInt32
        let name: String
        let frame: CGRect
        let serialNumber: String?
    }

    /// 简单的"一次性触发"标记，用于双链并行检测中让先命中的链通知另一链停止
    /// 所有访问均在主队列上，无需锁
    private final class AtomicFlag {
        private var _isSet = false
        var isSet: Bool { _isSet }
        /// 尝试设置：仅在未设置时成功，返回是否成功设置
        func trySet() -> Bool {
            if _isSet { return false }
            _isSet = true
            return true
        }
    }
    
    /// 获取当前屏幕映射
    private func getCurrentScreenMappings() -> [ScreenInfo] {
        var mappings: [ScreenInfo] = []
        for screen in NSScreen.screens {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let name = screen.localizedName
            // 使用 visibleFrame 获取可视区域（排除菜单栏和 Dock），确保窗口在可视区域内居中
            let frame = screen.visibleFrame
            let serialNumber = getScreenSerialNumber(for: screen)
            mappings.append(ScreenInfo(id: screenID, name: name, frame: frame, serialNumber: serialNumber))
        }
        return mappings
    }
    
    /// 获取屏幕序列号 - 与 AppDelegate 保持一致的格式
    private func getScreenSerialNumber(for screen: NSScreen) -> String? {
        guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              screenID != 0 else {
            return nil
        }
        
        // 获取屏幕序列号
        let serialNumber = CGDisplaySerialNumber(screenID)
        
        // 如果有有效序列号，优先使用
        if serialNumber != 0 {
            return "SN:\(serialNumber)"
        }
        
        // 否则使用 vendor + model 组合
        let vendorID = CGDisplayVendorNumber(screenID)
        let modelID = CGDisplayModelNumber(screenID)
        
        if vendorID != 0 {
            return "VM:\(vendorID)-\(modelID)"
        }
        
        // 最后使用 displayID 作为标识
        return "ID:\(screenID)"
    }
    
    /// 通过序列号查找屏幕
    private func findScreenBySerialNumber(_ serialNumber: String?, currentScreens: [ScreenInfo]) -> ScreenInfo? {
        guard let serial = serialNumber, !serial.isEmpty else { return nil }
        
        // 只进行精确匹配，避免错误匹配
        return currentScreens.first(where: { $0.serialNumber == serial })
    }
    
    /// 通过名称查找屏幕 frame
    private func findScreenFrameByName(_ name: String, currentScreens: [ScreenInfo]) -> CGRect? {
        // 首先尝试精确匹配
        if let exact = currentScreens.first(where: { $0.name == name }) {
            return exact.frame
        }
        // 尝试部分匹配（名称可能包含分辨率等信息）
        if let partial = currentScreens.first(where: { $0.name.contains(name) || name.contains($0.name) }) {
            return partial.frame
        }
        // 尝试匹配名称的第一个词（通常是不带分辨率的显示器名称）
        let nameFirstWord = name.components(separatedBy: " ").first ?? name
        if let firstMatch = currentScreens.first(where: { $0.name.components(separatedBy: " ").first == nameFirstWord }) {
            return firstMatch.frame
        }
        // 按索引匹配（如果只有一个屏幕，优先返回主屏幕）
        if currentScreens.count == 1 {
            return currentScreens.first?.frame
        }
        // 按屏幕顺序匹配（根据屏幕 x 坐标从左到右）
        let sorted = currentScreens.sorted { $0.frame.origin.x < $1.frame.origin.x }
        for (index, screen) in sorted.enumerated() {
            // 检查名称是否包含序号
            let nameIndex = "\(index + 1)"
            if name.contains(nameIndex) {
                return screen.frame
            }
        }
        return nil
    }
    
    /// 检查窗口位置并处理
    private func checkWindowPosition(pid: pid_t, targetFrame: CGRect, appBundleID: String, screenID: UInt32) {
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return
        }
        
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = getScreenContainingPoint(mouseLocation)
        
        for window in windows {
            let windowID = "\(pid)-\(window.hashValue)"
            
            var positionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
                  let posVal = positionValue else {
                continue
            }
            
            var axPosition = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &axPosition)
            
            // 如果窗口位置变化很小，跳过（使用容差处理浮点数精度问题）
            if let prev = previousWindowPositions[windowID],
               abs(prev.x - axPosition.x) < 1.0 && abs(prev.y - axPosition.y) < 1.0 {
                continue
            }
            
            previousWindowPositions[windowID] = axPosition
            
            // 如果已经在移动中，跳过
            if movingWindows.contains(windowID) {
                continue
            }
            
            // 检查鼠标是否在目标屏幕上
            if let currentScreen = mouseScreen,
               let currentScreenID = getScreenID(currentScreen),
               currentScreenID == screenID {
                continue
            }
            
            // 鼠标不在目标屏幕，移回目标屏幕
            movingWindows.insert(windowID)
            moveWindowToScreenCenter(window, targetFrame: targetFrame, windowID: windowID)
        }
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
    private func getScreenID(_ screenFrame: CGRect) -> UInt32? {
        for screen in NSScreen.screens {
            // 优先匹配 visibleFrame
            if screen.visibleFrame == screenFrame {
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
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.lastMovedWindows.remove(windowID)
                }
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
                    moveAppWindowsToScreen(pid: pid, targetFrame: matchedScreen.frame)
                }
                return
            }
        }
        
        // 备用：通过 ID 找屏幕
        guard let screenFrame = getScreenFrame(for: screenID) else { return }
        
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            let pid = app.processIdentifier
            moveAppWindowsToScreen(pid: pid, targetFrame: screenFrame)
        }
    }
    
    private func moveAppWindowsToScreen(pid: pid_t, targetFrame: CGRect) {
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return
        }
        
        for window in windows {
            moveWindowToFrameImmediate(window, targetFrame: targetFrame)
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
