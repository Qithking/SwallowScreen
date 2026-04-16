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
    private var launchedApps: Set<String> = [] // 已处理过的启动应用（用于一次性移动）
    
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
            Task { @MainActor [weak self] in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                self?.handleAppLaunch(bundleIdentifier: bundleID, pid: app.processIdentifier)
            }
        }
    }
    
    /// 处理应用启动
    private func handleAppLaunch(bundleIdentifier: String, pid: pid_t) {
        guard let modelContext = modelContext else { return }
        
        // 如果已经处理过这个应用（同一个 PID），跳过
        let appKey = "\(bundleIdentifier)-\(pid)"
        if launchedApps.contains(appKey) {
            return
        }
        
        // 查询应用配置
        let descriptor = FetchDescriptor<AppInfo>(
            predicate: #Predicate { $0.bundleIdentifier == bundleIdentifier && $0.isEnabled == true }
        )
        
        guard let appInfo = try? modelContext.fetch(descriptor).first else { return }
        
        // 如果设置了目标屏幕且没有启用固定屏幕，移动到目标屏幕一次
        if let targetScreenID = appInfo.targetScreenID, !appInfo.pinToScreen {
            guard let targetFrame = getScreenFrame(for: targetScreenID) else { return }
            
            // 立即尝试移动（窗口可能还没创建，所以多次重试）
            var retryCount = 0
            let maxRetries = 5
            
            func tryMoveWindow() {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    let moved = self.moveAppWindowsToScreenQuick(pid: pid, targetFrame: targetFrame)
                    if !moved && retryCount < maxRetries {
                        retryCount += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            tryMoveWindow()
                        }
                    } else {
                        self.launchedApps.insert(appKey)
                    }
                }
            }
            
            tryMoveWindow()
            
            // 3秒后移除记录，允许下次启动时重新移动
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.launchedApps.remove(appKey)
            }
        }
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
                
                // 尝试通过原始 ID 或名称匹配找到当前屏幕
                var targetScreenFrame: CGRect? = nil
                var targetScreenID: UInt32? = nil
                
                if let screenID = appInfo.targetScreenID {
                    targetScreenID = screenID
                    targetScreenFrame = getScreenFrame(for: screenID)
                }
                
                // 如果原始 ID 找不到，尝试通过名称匹配
                if targetScreenFrame == nil, let screenName = appInfo.targetScreenName {
                    targetScreenFrame = findScreenFrameByName(screenName, currentScreens: currentScreens)
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
    
    /// 获取当前屏幕映射
    private func getCurrentScreenMappings() -> [(id: UInt32, name: String, frame: CGRect)] {
        var mappings: [(id: UInt32, name: String, frame: CGRect)] = []
        for screen in NSScreen.screens {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let name = screen.localizedName
            let frame = screen.frame
            mappings.append((id: screenID, name: name, frame: frame))
        }
        return mappings
    }
    
    /// 通过名称查找屏幕 frame
    private func findScreenFrameByName(_ name: String, currentScreens: [(id: UInt32, name: String, frame: CGRect)]) -> CGRect? {
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
            if screen.frame == screenFrame {
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
        
        let centerX = targetFrame.midX - size.width / 2
        let centerY = targetFrame.midY - size.height / 2
        
        var position = CGPoint(x: centerX, y: centerY)
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
                return screen.frame
            }
        }
        return nil
    }
    
    /// 将应用窗口移动到指定屏幕（如果不在该屏幕）
    private func moveAppWindowsToScreenIfNeeded(pid: pid_t, targetFrame: CGRect, appBundleID: String) {
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return
        }
        
        let windowID = "\(pid)-menuBarApp"
        
        // 如果窗口已经在目标屏幕附近，跳过
        if let prev = previousWindowPositions[windowID] {
            if abs(prev.x - targetFrame.origin.x) < 50 && abs(prev.y - targetFrame.origin.y) < 50 {
                return
            }
        }
        
        for window in windows {
            // 检查窗口当前位置
            var positionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
                  let posVal = positionValue else {
                continue
            }
            
            var axPosition = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &axPosition)
            
            // 检查窗口是否在目标屏幕内
            if targetFrame.contains(axPosition) {
                previousWindowPositions[windowID] = axPosition
                continue
            }
            
            // 窗口不在目标屏幕，移动它
            movingWindows.insert(windowID)
            moveWindowToFrame(window, targetFrame: targetFrame)
            previousWindowPositions[windowID] = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.movingWindows.remove(windowID)
            }
        }
    }
    
    func moveAppToScreen(bundleIdentifier: String, screenID: UInt32) {
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
            moveWindowToFrame(window, targetFrame: targetFrame)
        }
    }
    
    /// 快速移动窗口到指定屏幕，返回是否成功
    private func moveAppWindowsToScreenQuick(pid: pid_t, targetFrame: CGRect) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        guard result == .success, let windows = windowsValue as? [AXUIElement], !windows.isEmpty else {
            return false
        }
        
        for window in windows {
            moveWindowToFrameImmediate(window, targetFrame: targetFrame)
        }
        return true
    }
    
    /// 立即移动窗口（无动画）
    private func moveWindowToFrameImmediate(_ window: AXUIElement, targetFrame: CGRect) {
        // 获取窗口尺寸
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        
        var size = CGSize.zero
        if let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }
        
        // 计算新位置（居中显示）
        let newPosition = CGPoint(
            x: targetFrame.origin.x + (targetFrame.width - size.width) / 2,
            y: targetFrame.origin.y + (targetFrame.height - size.height) / 2
        )
        
        // 设置窗口位置
        var position = newPosition
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
    }
    
    private func moveWindowToFrame(_ window: AXUIElement, targetFrame: CGRect) {
        // 获取窗口尺寸
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        
        var size = CGSize.zero
        if let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }
        
        // 计算新位置（居中显示）
        let newPosition = CGPoint(
            x: targetFrame.origin.x + (targetFrame.width - size.width) / 2,
            y: targetFrame.origin.y + (targetFrame.height - size.height) / 2
        )
        
        // 设置窗口位置
        var position = newPosition
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
    }
    
    func checkAccessibilityPermission() -> Bool {
        hasAccessibilityPermission = AXIsProcessTrusted()
        return hasAccessibilityPermission
    }
    
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    /// 立即触发窗口位置检查
    func triggerImmediateCheck() {
        checkAndEnforcePinnedWindows()
    }
}
