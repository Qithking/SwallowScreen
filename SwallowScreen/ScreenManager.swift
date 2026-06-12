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
    // R-159: 本字段为兼容历史保留，存的是 screen.frame（含菜单栏/Dock 区域）；
    //        判断屏幕包含关系请用 screen.visibleFrame（见 ScreenManager.screen(containing:)）
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

    // RT120: 持有 addObserver 返回的 token；不持立即被 ARC 释放
    private var observerToken: NSObjectProtocol?

    init() {
        refreshScreens()
        setupScreenChangeObserver()
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// RT7: 提供按 id/serialNumber/name 的统一查找接口
    func screen(id: CGDirectDisplayID) -> ScreenInfo? {
        return screens.first { $0.id == id }
    }

    func screen(serialNumber: String) -> ScreenInfo? {
        return screens.first { $0.serialNumber == serialNumber }
    }

    func screen(name: String) -> ScreenInfo? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return screens.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    /// RT7: 与 WindowMover.getScreenContainingPoint 统一用 visibleFrame
    func screen(containing point: CGPoint) -> ScreenInfo? {
        for screen in NSScreen.screens {
            if screen.visibleFrame.contains(point) {
                let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                if let cached = screens.first(where: { $0.id == screenID }) {
                    return cached
                }
                return ScreenInfo(
                    id: screenID,
                    name: screen.localizedName,
                    frame: screen.frame,
                    isMain: screen == NSScreen.main,
                    serialNumber: ScreenManager.serialNumber(for: screen)
                )
            }
        }
        return nil
    }

    func refreshScreens() {
        var screenList: [ScreenInfo] = []

        // 使用 NSScreen 获取屏幕信息（更可靠）
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGDirectDisplayID(index)
            let frame = screen.frame
            // 主屏幕判断：使用 CGDisplayIsMain API，与系统设置保持一致
            let isMain = (CGDisplayIsMain(screenID) != 0)
            let serialNumber = ScreenManager.serialNumber(for: screen)
            
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
    
    /// T11: 屏幕序列号统一入口（与 AppDelegate/WindowMover 中旧实现格式一致）
    /// 格式优先级：SN:CGDisplaySerialNumber → VM:vendor-model → ID:displayID
    static func serialNumber(for screen: NSScreen) -> String? {
        guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              screenID != 0 else {
            return nil
        }
        let serialNumber = CGDisplaySerialNumber(screenID)
        if serialNumber != 0 {
            return "SN:\(serialNumber)"
        }
        let vendorID = CGDisplayVendorNumber(screenID)
        let modelID = CGDisplayModelNumber(screenID)
        if vendorID != 0 {
            return "VM:\(vendorID)-\(modelID)"
        }
        return "ID:\(screenID)"
    }
    
    private func setupScreenChangeObserver() {
        // RT120: 持有 token——addObserver(forName:object:queue:using:) 返回的 token 必须被持有，
        //       否则 observer 立即被 ARC 释放，拔插屏幕后 refreshScreens 永不触发
        observerToken = NotificationCenter.default.addObserver(
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
