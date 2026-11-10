//
//  StatusBarIconTests.swift
//  SwallowScreenTests
//
//  菜单栏图标配置纯逻辑（模板渲染 + 标准尺寸缩放）的单元测试（swift test 运行）
//

import XCTest
import AppKit
@testable import SwallowScreenCore

final class StatusBarIconTests: XCTestCase {

    // 图标必须缩放到 18pt 标准尺寸（与系统状态栏图标一致），
    // 而非按资源原始点尺寸渲染（MenuIcon 为 24×24pt，直接渲染会偏大）
    func testApplyConfigurationScalesToStandardSide() {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        StatusBarIcon.applyConfiguration(to: image)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    // 配置后必须是模板图（系统自动适配深浅色外观）
    func testApplyConfigurationMarksAsTemplate() {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.isTemplate = false
        StatusBarIcon.applyConfiguration(to: image)
        XCTAssertTrue(image.isTemplate)
    }
}
