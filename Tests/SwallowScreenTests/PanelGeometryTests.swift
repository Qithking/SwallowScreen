//
//  PanelGeometryTests.swift
//  SwallowScreenTests
//
//  面板尺寸纯逻辑（clamp + 持久化恢复）的单元测试（swift test 运行）
//

import XCTest
@testable import SwallowScreenCore

final class PanelGeometryTests: XCTestCase {

    // MARK: - clampHeight

    // 低于最小高度 400 时被抬到 400
    func testClampHeightEnforcesMinimum() {
        XCTAssertEqual(PanelGeometry.clampHeight(350, screenVisibleHeight: 1000), 400)
    }

    // 超过上限 800 时被压到 800（屏幕足够高）
    func testClampHeightEnforcesAbsoluteCap() {
        XCTAssertEqual(PanelGeometry.clampHeight(900, screenVisibleHeight: 2000), 800)
    }

    // 屏幕可用高度低于 800 时以屏幕为上限
    func testClampHeightCapsAtScreenVisibleHeight() {
        XCTAssertEqual(PanelGeometry.clampHeight(900, screenVisibleHeight: 600), 600)
    }

    // 范围内的高度原样保留
    func testClampHeightKeepsValueInRange() {
        XCTAssertEqual(PanelGeometry.clampHeight(600, screenVisibleHeight: 1000), 600)
        XCTAssertEqual(PanelGeometry.clampHeight(400, screenVisibleHeight: 1000), 400)
        XCTAssertEqual(PanelGeometry.clampHeight(800, screenVisibleHeight: 1000), 800)
    }

    // 屏幕可用高度异常小（<400）时保住下限 400（与旧 NSPopover 实现行为一致）
    func testClampHeightHandlesTinyScreen() {
        XCTAssertEqual(PanelGeometry.clampHeight(900, screenVisibleHeight: 300), 400)
    }

    // MARK: - restoredHeight

    // 持久化值缺失（首次启动）回退默认 500
    func testRestoredHeightFallsBackToDefaultWhenMissing() {
        XCTAssertEqual(PanelGeometry.restoredHeight(persisted: nil, screenVisibleHeight: 1000), 500)
    }

    // 持久化值在范围内直接使用
    func testRestoredHeightUsesPersistedValue() {
        XCTAssertEqual(PanelGeometry.restoredHeight(persisted: 650, screenVisibleHeight: 1000), 650)
    }

    // 脏数据（超界）被 clamp 回范围内
    func testRestoredHeightClampsDirtyData() {
        XCTAssertEqual(PanelGeometry.restoredHeight(persisted: 10_000, screenVisibleHeight: 1000), 800)
        XCTAssertEqual(PanelGeometry.restoredHeight(persisted: -50, screenVisibleHeight: 1000), 400)
    }

    // 脏数据 + 超小屏组合：下限 400 优先于 screenCap（下限兜底保证面板可用）
    func testRestoredHeightClampsDirtyDataOnTinyScreen() {
        XCTAssertEqual(PanelGeometry.restoredHeight(persisted: 10_000, screenVisibleHeight: 300), 400)
    }
}
