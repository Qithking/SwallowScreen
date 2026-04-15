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
    @Published var defaultScreen: ScreenInfo?
    
    init() {
        refreshScreens()
        setupScreenChangeObserver()
    }
    
    func refreshScreens() {
        var screenList: [ScreenInfo] = []
        
        // 使用 NSScreen 获取屏幕信息（更可靠）
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGDirectDisplayID(index)
            let frame = screen.frame
            let isMain = screen == NSScreen.main
            
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
                isMain: isMain
            )
            screenList.append(info)
            
            if isMain {
                self.defaultScreen = info
            }
        }
        
        self.screens = screenList
    }
    
    func getScreen(by id: UInt32) -> ScreenInfo? {
        return screens.first { $0.id == id }
    }
    
    func getScreenContaining(point: CGPoint) -> ScreenInfo? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
                return screens.first { $0.id == screenID } ?? ScreenInfo(
                    id: screenID,
                    name: screen.localizedName,
                    frame: screen.frame,
                    isMain: screen == NSScreen.main
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
