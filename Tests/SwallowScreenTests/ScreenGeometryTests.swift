//
//  ScreenGeometryTests.swift
//  SwallowScreenTests
//
//  屏幕几何纯函数的单元测试（swift test 运行；问题24/D4）
//

import XCTest
import CoreGraphics
@testable import SwallowScreenCore

final class ScreenGeometryTests: XCTestCase {

    // 测试参考屏幕：主屏高度 900（BL 坐标系，Y 向上）
    private let screenHeight: CGFloat = 900

    // MARK: - visibleFrameToTL（BL → TL 转换）

    // 屏幕顶部的 frame：BL 的 maxY = 900 → TL origin.y = 0
    func testVisibleFrameToTLTopRegion() {
        let bl = CGRect(x: 100, y: 600, width: 800, height: 300)  // maxY = 900
        let tl = ScreenGeometry.visibleFrameToTL(bl, screenHeight: screenHeight)
        XCTAssertEqual(tl, CGRect(x: 100, y: 0, width: 800, height: 300))
    }

    // 屏幕底部的 frame：BL 的 maxY = 300 → TL origin.y = 600
    func testVisibleFrameToTLBottomRegion() {
        let bl = CGRect(x: 0, y: 0, width: 500, height: 300)  // maxY = 300
        let tl = ScreenGeometry.visibleFrameToTL(bl, screenHeight: screenHeight)
        XCTAssertEqual(tl, CGRect(x: 0, y: 600, width: 500, height: 300))
    }

    // X 轴与尺寸在转换中不变
    func testVisibleFrameToTLKeepsXAndSize() {
        let bl = CGRect(x: 37, y: 123, width: 640, height: 480)
        let tl = ScreenGeometry.visibleFrameToTL(bl, screenHeight: screenHeight)
        XCTAssertEqual(tl.minX, bl.minX)
        XCTAssertEqual(tl.width, bl.width)
        XCTAssertEqual(tl.height, bl.height)
        XCTAssertEqual(tl.maxY, screenHeight - bl.minY)
    }

    // MARK: - windowOverlapRatio（重叠面积占比）

    // 完全重叠 → 1.0
    func testOverlapRatioFullOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(ScreenGeometry.windowOverlapRatio(bounds, targetFrame: bounds), 1.0)
    }

    // 一半在目标区内 → 0.5
    func testOverlapRatioHalfOverlap() {
        let bounds = CGRect(x: 50, y: 0, width: 100, height: 100)   // 50% 落在 [0,100)
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(ScreenGeometry.windowOverlapRatio(bounds, targetFrame: target), 0.5)
    }

    // 完全分离 → 0
    func testOverlapRatioNoOverlap() {
        let bounds = CGRect(x: 200, y: 200, width: 100, height: 100)
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(ScreenGeometry.windowOverlapRatio(bounds, targetFrame: target), 0)
    }

    // 零面积窗口 → 0（除零防御）
    func testOverlapRatioZeroAreaBounds() {
        XCTAssertEqual(ScreenGeometry.windowOverlapRatio(.zero, targetFrame: CGRect(x: 0, y: 0, width: 100, height: 100)), 0)
    }

    // MARK: - isBoundsInTargetFrame（中心点 AND 50% 面积双条件）

    // 完全在目标区内 → true
    func testInTargetFrameFullyInside() {
        let targetBL = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let boundsTL = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertTrue(ScreenGeometry.isBoundsInTargetFrame(boundsTL, targetFrame: targetBL, screenHeight: screenHeight))
    }

    // 中心点在目标区外 → false（即使面积重叠 > 50%）
    func testInTargetFrameCenterOutside() {
        let targetBL = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // 窗口 x[950,1150)：中心 x=1050 在目标区外，重叠仅 25%
        let boundsTL = CGRect(x: 950, y: 300, width: 200, height: 200)
        XCTAssertFalse(ScreenGeometry.isBoundsInTargetFrame(boundsTL, targetFrame: targetBL, screenHeight: screenHeight))
    }

    // 中心点在区内但面积重叠 < 50% → false（窗口左/上两向溢出屏边）
    // 目标区 TL 为 x[0,1000] y[100,900]；窗口 x[-199,201) y[-99,301)，
    // 中心 (1,101) 在区内，但两轴重叠各约 50.25%，面积重叠约 25%
    func testInTargetFrameInsufficientOverlap() {
        let targetBL = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let boundsTL = CGRect(x: -199, y: -99, width: 400, height: 400)
        XCTAssertFalse(ScreenGeometry.isBoundsInTargetFrame(boundsTL, targetFrame: targetBL, screenHeight: screenHeight))
    }

    // 坐标系转换正确性：窗口位于目标屏底部（BL 低 y 区域 → TL 高 y 区域）也能正确判定
    func testInTargetFrameAtBottomOfScreen() {
        let targetBL = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let boundsTL = CGRect(x: 200, y: 700, width: 300, height: 200)  // 对应 BL y[0,200]
        XCTAssertTrue(ScreenGeometry.isBoundsInTargetFrame(boundsTL, targetFrame: targetBL, screenHeight: screenHeight))
    }
}
