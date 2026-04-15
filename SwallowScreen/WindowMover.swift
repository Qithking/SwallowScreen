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
    private var checkInterval: TimeInterval = 0.5  // 固定屏幕检查间隔（缩短到0.5秒）
    private var lastMovedWindows: Set<String> = [] // 记录上次移动的窗口，避免频繁移动
    
    init() {
        checkAccessibilityPermission()
    }
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        
        // 检查权限
        if !checkAccessibilityPermission() {
            print("⚠️ 没有辅助功能权限，无法控制窗口")
            requestAccessibilityPermission()
            return
        }
        
        isMonitoring = true
        
        // 使用 Timer 定期检查固定屏幕的应用
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndEnforcePinnedWindows()
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
        print("✅ WindowMover 监控已启动")
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        lastMovedWindows.removeAll()
    }
    
    /// 检查并强制执行固定屏幕规则
    private func checkAndEnforcePinnedWindows() {
        guard let modelContext = modelContext else { return }
        
        // 检查权限
        if !AXIsProcessTrusted() {
            return
        }
        
        // 获取所有启用了固定屏幕的应用
        let descriptor = FetchDescriptor<AppInfo>()
        
        do {
            let allApps = try modelContext.fetch(descriptor)
            let pinnedApps = allApps.filter { $0.pinToScreen && $0.targetScreenID != nil }
            
            for appInfo in pinnedApps {
                guard let targetScreenID = appInfo.targetScreenID else { continue }
                
                // 查找目标屏幕
                guard let targetScreen = getScreenFrame(for: targetScreenID) else { 
                    print("找不到目标屏幕: \(targetScreenID)")
                    continue 
                }
                
                // 查找该应用的所有窗口
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appInfo.bundleIdentifier).first {
                    let pid = app.processIdentifier
                    enforceAppOnScreen(pid: pid, targetFrame: targetScreen, appBundleID: appInfo.bundleIdentifier)
                }
            }
        } catch {
            print("Error fetching pinned apps: \(error)")
        }
    }
    
    /// 强制应用窗口保持在指定屏幕
    private func enforceAppOnScreen(pid: pid_t, targetFrame: CGRect, appBundleID: String) {
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return
        }
        
        for window in windows {
            // 检查窗口当前是否在允许的屏幕上
            let isOnScreen = isWindowOnAllowedScreen(window, allowedScreenFrame: targetFrame)
            
            if !isOnScreen {
                let windowID = "\(pid)-\(window.hashValue)"
                
                // 避免重复移动同一窗口
                if !lastMovedWindows.contains(windowID) {
                    lastMovedWindows.insert(windowID)
                    print("🔒 窗口超出边界，正在移回: \(appBundleID)")
                    moveWindowBackToAllowedScreen(window, targetFrame: targetFrame)
                    
                    // 3秒后移除记录，允许再次移动（如果用户故意移动）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        self?.lastMovedWindows.remove(windowID)
                    }
                }
            } else {
                // 窗口在正确屏幕上，移除记录
                let windowID = "\(pid)-\(window.hashValue)"
                lastMovedWindows.remove(windowID)
            }
        }
    }
    
    /// 检查窗口是否在允许的屏幕内（检查窗口左上角位置）
    private func isWindowOnAllowedScreen(_ window: AXUIElement, allowedScreenFrame: CGRect) -> Bool {
        var positionValue: CFTypeRef?
        let posResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        
        guard posResult == .success, let posVal = positionValue else {
            return true // 无法获取位置，假设正确
        }
        
        var position = CGPoint.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        
        // 检查窗口左上角是否在屏幕内（更严格的检查）
        let isInside = allowedScreenFrame.contains(position)
        
        // 也检查窗口大部分是否在屏幕内
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        
        if let szVal = sizeValue {
            var size = CGSize.zero
            AXValueGetValue(szVal as! AXValue, .cgSize, &size)
            
            // 窗口右上角
            let topRight = CGPoint(x: position.x + size.width, y: position.y)
            // 窗口左下角
            let bottomLeft = CGPoint(x: position.x, y: position.y + size.height)
            
            // 如果窗口左上角和右下角都在屏幕内，认为窗口在正确屏幕
            return allowedScreenFrame.contains(topRight) || allowedScreenFrame.contains(bottomLeft) || isInside
        }
        
        return isInside
    }
    
    /// 将窗口移回允许的屏幕
    private func moveWindowBackToAllowedScreen(_ window: AXUIElement, targetFrame: CGRect) {
        // 获取窗口尺寸
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        
        var size = CGSize.zero
        if let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }
        
        // 计算新位置（保持在目标屏幕内，靠近最近的边界）
        // 获取当前窗口位置
        var positionValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        
        var currentPosition = CGPoint.zero
        if let posVal = positionValue {
            AXValueGetValue(posVal as! AXValue, .cgPoint, &currentPosition)
        }
        
        // 计算新位置（保持在目标屏幕内）
        var newPosition = currentPosition
        
        // 计算屏幕边界
        let screenMinX = targetFrame.minX
        let screenMaxX = targetFrame.maxX - size.width
        let screenMinY = targetFrame.minY
        let screenMaxY = targetFrame.maxY - size.height
        
        // 限制 X 坐标
        if newPosition.x < screenMinX {
            newPosition.x = screenMinX
        } else if newPosition.x > screenMaxX {
            newPosition.x = max(screenMinX, screenMaxX)
        }
        
        // 限制 Y 坐标
        if newPosition.y < screenMinY {
            newPosition.y = screenMinY
        } else if newPosition.y > screenMaxY {
            newPosition.y = max(screenMinY, screenMaxY)
        }
        
        // 设置窗口位置
        var position = newPosition
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
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
}
