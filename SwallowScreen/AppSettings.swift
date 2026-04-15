//
//  AppSettings.swift
//  SwallowScreen
//
//  应用全局设置模型
//

import Foundation
import SwiftData

@Model
final class AppSettings {
    // 是否开机启动
    var launchAtLogin: Bool
    
    // 是否在菜单栏显示图标
    var showInMenuBar: Bool
    
    // 应用窗口是否跟随规则移动
    var enableAutoMove: Bool
    
    // 是否显示帮助提示
    var showHelpTips: Bool
    
    // 记录窗口位置的检查间隔（秒）
    var checkInterval: Double
    
    // 创建时间
    var createdAt: Date
    
    // 更新时间
    var updatedAt: Date
    
    init(launchAtLogin: Bool = false, showInMenuBar: Bool = true, enableAutoMove: Bool = true, showHelpTips: Bool = true, checkInterval: Double = 2.0) {
        self.launchAtLogin = launchAtLogin
        self.showInMenuBar = showInMenuBar
        self.enableAutoMove = enableAutoMove
        self.showHelpTips = showHelpTips
        self.checkInterval = checkInterval
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
