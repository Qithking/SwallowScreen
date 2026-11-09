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
    // name 仅存 screen.localizedName，不含分辨率后缀——分辨率会随设置变化导致匹配失败；
    // 分辨率信息在 resolutionSuffix 中，仅用于 UI 展示
    let name: String
    // 兼容历史保留：存的是 screen.frame（含菜单栏/Dock 区域）；
    // 判断屏幕包含关系请用 visibleFrame（见 screen(containing:)）
    let frame: CGRect
    // 可用区域（排除菜单栏/Dock）
    let visibleFrame: CGRect
    let isMain: Bool
    let serialNumber: String?  // 屏幕序列号，用于跨重启识别
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

    // 持有 addObserver 返回的 token，否则会被 ARC 立即释放
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

    /// 提供按 id/serialNumber/name 的查找接口
    func screen(id: CGDirectDisplayID) -> ScreenInfo? {
        return screens.first { $0.id == id }
    }

    func screen(serialNumber: String) -> ScreenInfo? {
        return screens.first { $0.serialNumber == serialNumber }
    }

    func screen(name: String) -> ScreenInfo? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 精确匹配：优先匹配 ScreenInfo.name（仅 localizedName，不含分辨率）
        if let exact = screens.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }
        // 兼容旧版本：targetScreenName 可能带分辨率后缀（如 "DELL U2720Q (2560x1440)"），
        // 故做前缀匹配，剩余部分须以 "(" 或数字开头才命中
        for screen in screens {
            let screenName = screen.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !screenName.isEmpty && normalized.caseInsensitiveCompare(screenName) != .orderedSame
                && normalized.hasPrefix(screenName) {
                let suffix = normalized.dropFirst(screenName.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if suffix.hasPrefix("(") || suffix.first?.isNumber == true {
                    return screen
                }
            }
        }
        return nil
    }

    /// 使用 visibleFrame 匹配
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
                    visibleFrame: screen.visibleFrame,
                    isMain: screen == NSScreen.main,
                    serialNumber: ScreenManager.serialNumber(for: screen),
                    resolutionSuffix: nil  // 兜底构造，不含分辨率后缀
                )
            }
        }
        return nil
    }

    /// 按 App 配置解析目标屏幕
    /// 匹配优先级：serialNumber → screenID → screenName
    /// - Returns: 匹配到的 ScreenInfo（含 frame/visibleFrame/id，供搬窗与可见区判定使用）
    func resolveTarget(for appInfo: AppInfo) -> ScreenInfo? {
        if let serialNumber = appInfo.targetScreenSerialNumber,
           let matched = screen(serialNumber: serialNumber) {
            return matched
        }
        if let screenID = appInfo.targetScreenID,
           let matched = screen(id: screenID) {
            return matched
        }
        if let screenName = appInfo.targetScreenName,
           let matched = screen(name: screenName) {
            return matched
        }
        return nil
    }

    func refreshScreens() {
        var screenList: [ScreenInfo] = []

        // 使用 NSScreen 获取屏幕信息
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGDirectDisplayID(index)
            let frame = screen.frame
            // 主屏幕判断：使用 CGDisplayIsMain API，与系统设置保持一致
            let isMain = (CGDisplayIsMain(screenID) != 0)
            let serialNumber = ScreenManager.serialNumber(for: screen)

            var screenName = "屏幕 \(index + 1)"
            let name = screen.localizedName
            if !name.isEmpty {
                screenName = name
            }
            
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
                visibleFrame: screen.visibleFrame,
                isMain: isMain,
                serialNumber: serialNumber,
                resolutionSuffix: resolutionSuffix
            )
            screenList.append(info)
        }
        
        // 内容未变时不赋值，避免无谓触发 SwiftUI 刷新
        if screenList != screens {
            self.screens = screenList
        }
    }
    
    /// 屏幕序列号获取入口
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
        // addObserver 返回的 token 必须被持有，否则 observer 立即被 ARC 释放，
        // 拔插屏幕后 refreshScreens 永不触发
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
