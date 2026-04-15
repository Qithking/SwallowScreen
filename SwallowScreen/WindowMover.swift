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
    private var checkInterval: TimeInterval = 2.0
    
    init() {
        checkAccessibilityPermission()
    }
    
    func configure(modelContext: ModelContext, interval: TimeInterval = 2.0) {
        self.modelContext = modelContext
        self.checkInterval = interval
    }
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        // 使用 Timer 定期检查窗口位置
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndMoveWindows()
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }
    
    private func checkAndMoveWindows() {
        guard let modelContext = modelContext else { return }
        
        // 获取所有已配置的应用
        let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.isEnabled })
        
        do {
            let configuredApps = try modelContext.fetch(descriptor)
            
            for appInfo in configuredApps {
                guard let targetScreenID = appInfo.targetScreenID else { continue }
                
                // 查找目标屏幕的 frame
                guard let targetScreen = getScreenFrame(for: targetScreenID) else { continue }
                
                // 查找该应用的所有窗口
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: appInfo.bundleIdentifier).first {
                    let pid = app.processIdentifier
                    moveAppWindowsToScreen(pid: pid, targetFrame: targetScreen)
                }
            }
        } catch {
            print("Error fetching app info: \(error)")
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
    
    func moveAppToScreen(bundleIdentifier: String, screenID: UInt32) {
        guard let screenFrame = getScreenFrame(for: screenID) else { return }
        
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            let pid = app.processIdentifier
            moveAppWindowsToScreen(pid: pid, targetFrame: screenFrame)
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
