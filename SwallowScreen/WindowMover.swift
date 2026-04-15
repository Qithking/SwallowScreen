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
            
            let pinnedApps = allApps.filter { $0.pinToScreen && $0.targetScreenID != nil }
            
            for appInfo in pinnedApps {
                guard let targetScreenID = appInfo.targetScreenID,
                      let targetScreenFrame = getScreenFrame(for: targetScreenID),
                      let app = NSRunningApplication.runningApplications(withBundleIdentifier: appInfo.bundleIdentifier).first else {
                    continue
                }
                
                let pid = app.processIdentifier
                checkWindowPosition(pid: pid, targetFrame: targetScreenFrame, appBundleID: appInfo.bundleIdentifier, screenID: targetScreenID)
            }
        } catch {
            // 静默处理错误
        }
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
