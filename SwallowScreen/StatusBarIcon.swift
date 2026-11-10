//
//  StatusBarIcon.swift
//  SwallowScreen
//
//  菜单栏状态图标配置纯函数，随 SwallowScreenCore 编译进单元测试
//  （GUI 主模块含 SwiftData/@Preview，无法独立编译）。
//

import AppKit

enum StatusBarIcon {

    /// macOS 菜单栏图标标准绘制尺寸：Apple HIG 状态栏图标在 ~18pt 内渲染，
    /// 与系统 Wi-Fi/电池等图标视觉一致（MenuIcon 资源为 24×24pt，直接渲染会偏大）
    static let side: CGFloat = 18

    /// 配置菜单栏图标：模板渲染（自动适配深浅色）+ 缩放到标准尺寸。
    /// 直接修改传入实例（asset catalog 缓存实例，调用方独占使用）
    static func applyConfiguration(to image: NSImage) {
        image.isTemplate = true
        image.size = NSSize(width: side, height: side)
    }
}
