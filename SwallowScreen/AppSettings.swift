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
    var launchAtLogin: Bool

    var showHelpTips: Bool

    var checkUpdateOnLaunch: Bool

    var setScreenKeyCode: Int32

    var setScreenModifiers: UInt32

    var clearScreenKeyCode: Int32

    var clearScreenModifiers: UInt32

    // 行内默认值同时作为 SwiftData 轻量迁移默认值：老 Store 记录读取时自动填充
    var updateChannel: String = UpdateChannel.github.rawValue

    // 面板高度（拖拽调整，400-800 范围内）；行内默认 500 兼容老记录
    var popoverHeight: Double = 500

    var createdAt: Date

    var updatedAt: Date

    init() {
        self.launchAtLogin = false
        self.showHelpTips = true
        self.checkUpdateOnLaunch = true
        self.setScreenKeyCode = 0x18  // 数字键1
        self.setScreenModifiers = UInt32(cmdKey | shiftKey)
        self.clearScreenKeyCode = 0x19 // 数字键2
        self.clearScreenModifiers = UInt32(cmdKey | shiftKey)
        self.updateChannel = UpdateChannel.github.rawValue
        self.popoverHeight = 500
        self.createdAt = Date()
        self.updatedAt = Date()
    }

}
