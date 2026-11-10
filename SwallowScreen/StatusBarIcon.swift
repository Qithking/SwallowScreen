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

    /// 加载菜单栏图标：优先 Asset Catalog（Xcode 工程构建产物含 Assets.car），
    /// 回落 bundle Resources 裸 png（发布版 SPM 构建手工拼 bundle，不含 Assets.car，
    /// 由 CI 把 MenuIcon.imageset 的 png 拷入 Resources）；两者皆无返回 nil，
    /// 调用方继续走系统符号 fallback
    static func loadMenuIcon(in bundle: Bundle) -> NSImage? {
        if let image = NSImage(named: "MenuIcon") {
            applyConfiguration(to: image)
            return image
        }
        // @2x 优先（retina 清晰度）；点尺寸统一由 applyConfiguration 覆盖为 18pt
        for name in ["menu_icon@2x", "menu_icon@3x", "menu_icon"] {
            if let url = bundle.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                applyConfiguration(to: image)
                return image
            }
        }
        return nil
    }
}
