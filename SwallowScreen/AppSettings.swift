//
//  AppSettings.swift
//  SwallowScreen
//
//  应用全局设置模型
//

import Foundation
import SwiftData
import Carbon.HIToolbox

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
    
    // 设置屏幕快捷键 - 键码 (默认: 0x18 = 1键)
    var setScreenKeyCode: Int32
    
    // 设置屏幕快捷键 - 修饰键 (默认: cmd + shift)
    var setScreenModifiers: UInt32
    
    // 清除屏幕快捷键 - 键码 (默认: 0x19 = 2键)
    var clearScreenKeyCode: Int32
    
    // 清除屏幕快捷键 - 修饰键 (默认: cmd + shift)
    var clearScreenModifiers: UInt32
    
    // 创建时间
    var createdAt: Date
    
    // 更新时间
    var updatedAt: Date
    
    init() {
        self.launchAtLogin = false
        self.showInMenuBar = true
        self.enableAutoMove = true
        self.showHelpTips = true
        self.checkInterval = 2.0
        self.setScreenKeyCode = 0x18  // 数字键1
        self.setScreenModifiers = UInt32(cmdKey | shiftKey)
        self.clearScreenKeyCode = 0x19 // 数字键2
        self.clearScreenModifiers = UInt32(cmdKey | shiftKey)
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
