//
//  ScreenManager.swift
//  SwallowScreen
//
//  屏幕/显示器管理器
//

import Foundation
import AppKit
import Combine
import CoreGraphics

struct ScreenInfo: Identifiable, Hashable {
    let id: UInt32  // CGDirectDisplayID
    let name: String
    let frame: CGRect
    let isMain: Bool
    let serialNumber: String?  // 屏幕序列号，用于跨重启识别
    
    var displayName: String {
        if isMain {
            return "主屏幕 (\(name))"
        }
        return name
    }
}

@MainActor
class ScreenManager: ObservableObject {
    @Published var screens: [ScreenInfo] = []
    
    init() {
        refreshScreens()
        setupScreenChangeObserver()
    }
    
    /// 获取屏幕序列号 - 与 WindowMover/AppDelegate 保持一致
    private func getScreenSerialNumber(for screenID: CGDirectDisplayID) -> String? {
        guard screenID != 0 else { return nil }
        
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
    
    func refreshScreens() {
        var screenList: [ScreenInfo] = []
        
        // 使用 CGDisplayIsMain 获取系统主屏幕（比 NSScreen.main 更可靠）
        let mainDisplayID = CGMainDisplayID()
        
        // 使用 NSScreen 获取屏幕信息（更可靠）
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGDirectDisplayID(index)
            let frame = screen.frame
            // 主屏幕判断：使用 CGDisplayIsMain API，与系统设置保持一致
            let isMain = (CGDisplayIsMain(screenID) != 0)
            let serialNumber = getScreenSerialNumber(for: screenID)
            
            // 获取屏幕名称
            var screenName = "屏幕 \(index + 1)"
            let name = screen.localizedName
            if !name.isEmpty {
                screenName = name
            }
            
            // 如果是 Retina 屏幕或外接显示器，添加分辨率信息
            if screen.backingScaleFactor > 1.0 && NSScreen.screens.count > 1 {
                let resolution = "\(Int(frame.width))x\(Int(frame.height))"
                if !screenName.contains(resolution) {
                    screenName = "\(screenName) \(resolution)"
                }
            }
            
            let info = ScreenInfo(
                id: screenID,
                name: screenName,
                frame: frame,
                isMain: isMain,
                serialNumber: serialNumber
            )
            screenList.append(info)
        }
        
        self.screens = screenList
    }
    
    func getScreenContaining(point: CGPoint) -> ScreenInfo? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                let serialNumber = getScreenSerialNumber(for: screenID)
                return screens.first { $0.id == screenID } ?? ScreenInfo(
                    id: screenID,
                    name: screen.localizedName,
                    frame: screen.frame,
                    isMain: screen == NSScreen.main,
                    serialNumber: serialNumber
                )
            }
        }
        return nil
    }
    
    private func setupScreenChangeObserver() {
        // 使用 NotificationCenter 监听屏幕变化
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshScreens()
                NotificationCenter.default.post(name: .screenConfigurationChanged, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let screenConfigurationChanged = Notification.Name("screenConfigurationChanged")
}
