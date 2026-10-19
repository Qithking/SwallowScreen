//
//  AppSettings.swift
//  SwallowScreen
//
//  应用全局设置模型
//

import Foundation
import SwiftData
import Carbon.HIToolbox
// SPM 构建下 UpdateChannel 位于 SwallowScreenCore 模块；Xcode 工程为平面 target 无需 import
#if canImport(SwallowScreenCore)
import SwallowScreenCore
#endif

@Model
final class AppSettings {
    // 是否开机启动
    var launchAtLogin: Bool

    // 是否显示帮助提示
    var showHelpTips: Bool

    // 启动时是否检查更新
    var checkUpdateOnLaunch: Bool

    // 设置屏幕快捷键 - 键码 (默认: 0x18 = 1键)
    var setScreenKeyCode: Int32

    // 设置屏幕快捷键 - 修饰键 (默认: cmd + shift)
    var setScreenModifiers: UInt32

    // 清除屏幕快捷键 - 键码 (默认: 0x19 = 2键)
    var clearScreenKeyCode: Int32

    // 清除屏幕快捷键 - 修饰键 (默认: cmd + shift)
    var clearScreenModifiers: UInt32

    // 更新下载渠道 rawValue（UpdateChannel；默认官网直连）
    // 行内默认值同时作为 SwiftData 轻量迁移默认值：老 Store 记录读取时自动填充
    var updateChannel: String = UpdateChannel.github.rawValue

    // 创建时间
    var createdAt: Date

    // 更新时间
    var updatedAt: Date

    init() {
        self.launchAtLogin = false
        self.showHelpTips = true
        self.checkUpdateOnLaunch = true  // 默认启动时检查更新
        self.setScreenKeyCode = 0x18  // 数字键1
        self.setScreenModifiers = UInt32(cmdKey | shiftKey)
        self.clearScreenKeyCode = 0x19 // 数字键2
        self.clearScreenModifiers = UInt32(cmdKey | shiftKey)
        self.updateChannel = UpdateChannel.github.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // RT126: 删除 showInMenuBar 死字段（grep 整个代码库 0 引用）
}
