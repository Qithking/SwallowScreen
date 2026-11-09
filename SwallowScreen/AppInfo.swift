//
//  AppInfo.swift
//  SwallowScreen
//
//  应用信息模型，用于存储单个应用与屏幕的关联配置
//

import Foundation
import SwiftData

@Model
final class AppInfo {
    var bundleIdentifier: String

    var appName: String

    // 目标屏幕 ID（CGDirectDisplayID）
    var targetScreenID: UInt32?

    var targetScreenName: String?

    // 屏幕序列号（跨重启识别屏幕）
    var targetScreenSerialNumber: String?

    var isEnabled: Bool

    // 是否固定屏幕 - 开启后应用只能在该屏幕移动，不允许移到其他屏幕
    var pinToScreen: Bool

    // 窗口标题匹配模式
    // nil 或空字符串 = 匹配该应用所有窗口（默认行为）
    // 非空 = 仅匹配标题包含该字符串的窗口（大小写不敏感）
    // 示例："Settings" 仅匹配标题含 Settings 的窗口，其他窗口不受影响
    var windowTitlePattern: String?

    var createdAt: Date

    var updatedAt: Date

    init(bundleIdentifier: String, appName: String, targetScreenID: UInt32? = nil, targetScreenName: String? = nil, targetScreenSerialNumber: String? = nil, isEnabled: Bool = true, pinToScreen: Bool = false, windowTitlePattern: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.targetScreenID = targetScreenID
        self.targetScreenName = targetScreenName
        self.targetScreenSerialNumber = targetScreenSerialNumber
        self.isEnabled = isEnabled
        self.pinToScreen = pinToScreen
        self.windowTitlePattern = windowTitlePattern
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    func updateScreen(screenID: UInt32?, screenName: String?, screenSerialNumber: String?) {
        self.targetScreenID = screenID
        self.targetScreenName = screenName
        self.targetScreenSerialNumber = screenSerialNumber
        self.updatedAt = Date()
    }
    
    func updatePinToScreen(_ pinned: Bool) {
        self.pinToScreen = pinned
        // 开启 pin 时强制 isEnabled = true，确保 pin 监控路径不被整体跳过
        if pinned && !isEnabled {
            isEnabled = true
        }
        self.updatedAt = Date()
    }
}
