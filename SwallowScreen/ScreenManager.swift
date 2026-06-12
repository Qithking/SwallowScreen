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
    // R-222: name 仅存 screen.localizedName，不含分辨率后缀——
    //        分辨率会随设置变化，导致 targetScreenName 匹配失败；
    //        分辨率信息移到 displayName 中仅用于 UI 展示
    let name: String
    // R-159: 本字段为兼容历史保留，存的是 screen.frame（含菜单栏/Dock 区域）；
    //        判断屏幕包含关系请用 screen.visibleFrame（见 ScreenManager.screen(containing:)）
    let frame: CGRect
    let isMain: Bool
    let serialNumber: String?  // 屏幕序列号，用于跨重启识别
    // R-222: 分辨率后缀独立存储，仅用于 UI 展示
    let resolutionSuffix: String?
    
    var displayName: String {
        var base: String
        if isMain {
            base = "主屏幕 (\(name))"
        } else {
            base = name
        }
        if let suffix = resolutionSuffix {
            return "\(base) \(suffix)"
        }
        return base
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
        // R-228: 精确匹配——优先匹配 ScreenInfo.name（仅 localizedName，R-222 后不含分辨率）
        if let exact = screens.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }
        // R-228: 兼容旧版本——旧版存储的 targetScreenName 可能含分辨率后缀
        //        （如 "DELL U2720Q (2560x1440)"），R-222 后 name 仅 localizedName
        //        遍历所有屏，检查 normalized 是否以某个 screen.name 开头
        //        （分辨率后缀格式为 " (WxH)"，空格+括号分隔）
        for screen in screens {
            let screenName = screen.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !screenName.isEmpty && normalized.caseInsensitiveCompare(screenName) != .orderedSame
                && normalized.hasPrefix(screenName) {
                // 剩余部分应是分辨率后缀，格式 " (WxH)" 或 " WxH"
                let suffix = normalized.dropFirst(screenName.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if suffix.hasPrefix("(") || suffix.first?.isNumber == true {
                    return screen
                }
            }
        }
        return nil
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
                    serialNumber: ScreenManager.serialNumber(for: screen),
                    resolutionSuffix: nil  // 兜底构造，不含分辨率后缀
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
            // R-222: name 仅存 localizedName（稳定，不随分辨率变化）；
            //        分辨率后缀存到 resolutionSuffix（仅用于 UI 展示）
            var screenName = "屏幕 \(index + 1)"
            let name = screen.localizedName
            if !name.isEmpty {
                screenName = name
            }
            
            // 如果是 Retina 屏幕或外接显示器，生成分辨率后缀
            var resolutionSuffix: String? = nil
            if screen.backingScaleFactor > 1.0 && NSScreen.screens.count > 1 {
                let resolution = "\(Int(frame.width))x\(Int(frame.height))"
                if !screenName.contains(resolution) {
                    resolutionSuffix = resolution
                }
            }
            
            let info = ScreenInfo(
                id: screenID,
                name: screenName,
                frame: frame,
                isMain: isMain,
                serialNumber: serialNumber,
                resolutionSuffix: resolutionSuffix
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
    // AXObserver 内部桥接通知：C 回调无法直接访问 @MainActor，通过 NotificationCenter 桥接
    static let axWindowCreatedInternal = Notification.Name("axWindowCreatedInternal")
}
