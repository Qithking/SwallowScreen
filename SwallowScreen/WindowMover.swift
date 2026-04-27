//
//  WindowMover.swift
//  SwallowScreen
//
//  窗口管理器 - 监控和移动应用窗口
//

import Foundation
import AppKit
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
            
            // 轮询等待窗口创建并立即移动
            pollForWindows(pid: pid, targetFrame: finalTargetFrame)
        }
    }
    
    /// 轮询等待窗口创建并立即移动
    private func pollForWindows(pid: pid_t, targetFrame: CGRect) {
        let maxAttempts = 30  // 最多 3 秒
        var attempts = 0
        
        func tryMove() {
            guard attempts < maxAttempts else { return }
            attempts += 1
            
            guard NSRunningApplication(processIdentifier: pid) != nil else { return }
            
            let appElement = AXUIElementCreateApplication(pid)
            var windowsValue: CFTypeRef?
            
            let result = AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsValue
            )
            
            if result == .success, let windows = windowsValue as? [AXUIElement], !windows.isEmpty {
                for window in windows {
                    moveWindowToFrameImmediate(window, targetFrame: targetFrame)
                }
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                tryMove()
            }
        }
        
        tryMove()
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
            self.timer = Timer.scheduledTimer(withTimeInterval: self.checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkAndEnforcePinnedWindows()
                }
            }
            RunLoop.current.add(self.timer!, forMode: .common)
        }
        return true
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
            
            // 如果窗口位置没变，跳过
            if let prev = previousWindowPositions[windowID],
               prev.x == axPosition.x && prev.y == axPosition.y {
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
            let screenFrame = screen.frame
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
        
        // 使用与 moveWindowToFrameImmediate 相同的计算方式，确保窗口在可视区域内正确居中
        let newPosition = CGPoint(
            x: targetFrame.origin.x + (targetFrame.width - size.width) / 2,
            y: (targetFrame.height - size.height) / 2
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
            }
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
