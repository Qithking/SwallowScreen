//
//  ScreenGeometry.swift
//  SwallowScreen
//
//  屏幕几何纯函数（问题24/D4 架构深化）
//  原 WindowMover 内三个无状态几何判定函数外移至此，随 SwallowScreenCore
//  编译进单元测试（GUI 主模块含 SwiftData/@Preview 无法独立编译）。
//
//  坐标系说明：
//  - bounds（窗口）：CGWindowList / AX 均为 TL 坐标系（左上原点，Y 向下）
//  - targetFrame（屏幕 visibleFrame）：NSScreen 为 BL 坐标系（左下原点，Y 向上）
//  - 转换公式：y_TL = primaryScreenHeight - y_BL（主屏幕高度为公共参考面）
//

import CoreGraphics

enum ScreenGeometry {

    /// 将 visibleFrame（BL 坐标系）转换为 TL 坐标系
    /// - Parameter screenHeight: 主屏幕高度（NSScreen.screens[0].frame.height）
    static func visibleFrameToTL(_ frame: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: screenHeight - frame.maxY,  // BL 的 maxY = 顶部 → TL 的 origin.y
            width: frame.width,
            height: frame.height
        )
    }

    /// 计算窗口 bounds 与目标区域的重叠面积占窗口总面积的比例（0...1）
    static func windowOverlapRatio(_ bounds: CGRect, targetFrame: CGRect) -> CGFloat {
        let intersection = bounds.intersection(targetFrame)
        if intersection.isNull || intersection.isEmpty { return 0 }
        let windowArea = bounds.width * bounds.height
        guard windowArea > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        return intersectionArea / windowArea
    }

    /// 判断窗口是否"在目标屏合理位置"：中心点在 visibleFrame 内 AND 至少 50% 面积重叠
    /// （FIX-自由移动 引入的双条件判定）
    static func isBoundsInTargetFrame(_ bounds: CGRect,
                                      targetFrame: CGRect,
                                      screenHeight: CGFloat) -> Bool {
        let targetFrameTL = visibleFrameToTL(targetFrame, screenHeight: screenHeight)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard targetFrameTL.contains(center) else { return false }
        return windowOverlapRatio(bounds, targetFrame: targetFrameTL) >= 0.5
    }
}
