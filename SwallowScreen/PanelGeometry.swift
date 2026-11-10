//
//  PanelGeometry.swift
//  SwallowScreen
//
//  面板尺寸纯函数，随 SwallowScreenCore 编译进单元测试
//  （GUI 主模块含 SwiftData/@Preview，无法独立编译）。
//
//  NSPanel 方案：拖拽 resize 由窗口系统原生处理，此处仅承载
//  高度 clamp 与持久化恢复这两个自有逻辑边界。
//

import CoreGraphics

// public：Core 以独立模块被 GUI 主模块 import（SPM 双 target 结构），
// 无 public 修饰（= internal）会导致跨模块符号不可见（CI swift build 失败根因）
public enum PanelGeometry {

    /// 面板固定宽度（NSPanel 内容区与 SwiftUI 根视图共用）
    public static let panelWidth: CGFloat = 360
    /// 高度下限
    public static let minHeight: CGFloat = 400
    /// 高度上限（屏幕可用高度内的绝对上限）
    public static let maxHeight: CGFloat = 800
    /// 默认高度（无持久化记录时）
    public static let defaultHeight: CGFloat = 500

    /// 面板高度 clamp：400 ~ min(800, 屏幕可用高度)
    /// 屏幕可用高度异常小（<400）时保住下限，与旧 NSPopover 实现行为一致
    public static func clampHeight(_ height: CGFloat, screenVisibleHeight: CGFloat) -> CGFloat {
        let screenCap = max(minHeight, screenVisibleHeight)
        return min(max(height, minHeight), min(maxHeight, screenCap))
    }

    /// 恢复面板高度：持久化值缺失回退默认 500，再经 clamp 兜住脏数据
    public static func restoredHeight(persisted: Double?, screenVisibleHeight: CGFloat) -> CGFloat {
        clampHeight(CGFloat(persisted ?? Double(defaultHeight)), screenVisibleHeight: screenVisibleHeight)
    }
}
