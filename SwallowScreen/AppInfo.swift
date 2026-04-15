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
    
    // 应用图标数据（存储为 Data）
    var iconData: Data?
    
    // 指定的屏幕 ID（通过 CGDirectDisplayID 标识）
    var targetScreenID: UInt32?
    
    // 屏幕名称（用于显示）
    var targetScreenName: String?
    
    // 是否启用该应用的屏幕规则
    var isEnabled: Bool
    
    // 创建时间
    var createdAt: Date
    
    // 更新时间
    var updatedAt: Date
    
    init(bundleIdentifier: String, appName: String, iconData: Data? = nil, targetScreenID: UInt32? = nil, targetScreenName: String? = nil, isEnabled: Bool = true) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.iconData = iconData
        self.targetScreenID = targetScreenID
        self.targetScreenName = targetScreenName
        self.isEnabled = isEnabled
        self.createdAt = Date()
        self.updatedAt = Date()
    }
    
    func updateScreen(screenID: UInt32?, screenName: String?) {
        self.targetScreenID = screenID
        self.targetScreenName = screenName
        self.updatedAt = Date()
    }
}
