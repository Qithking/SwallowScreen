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
    // 应用 Bundle Identifier
    var bundleIdentifier: String

    // 应用名称
    var appName: String

    // 指定的屏幕 ID（通过 CGDirectDisplayID 标识）
    var targetScreenID: UInt32?

    // 屏幕名称（用于显示）
    var targetScreenName: String?

    // 屏幕序列号（用于唯一识别屏幕，跨系统重启仍然有效）
    var targetScreenSerialNumber: String?

    // 是否启用该应用的屏幕规则
    var isEnabled: Bool

    // 是否固定屏幕 - 开启后应用只能在该屏幕移动，不允许移到其他屏幕
    var pinToScreen: Bool

    // 窗口标题匹配模式（借鉴 yabai rule 系统）
    // nil 或空字符串 = 匹配该应用所有窗口（默认行为）
    // 非空 = 仅匹配标题包含该字符串的窗口（大小写不敏感）
    // 示例："Settings" 仅匹配标题含 Settings 的窗口，其他窗口不受影响
    var windowTitlePattern: String?

    // 创建时间
    var createdAt: Date

    // 更新时间
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
        // T9: 开启 pin 时强制 isEnabled = true，确保 pin 监控路径不被整体跳过
        if pinned && !isEnabled {
            isEnabled = true
        }
        self.updatedAt = Date()
    }
}
