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

    // MARK: - loadMenuIcon（发布版 bundle 资源加载）

    // 构造最小 fake bundle：临时目录 + Info.plist + 指定资源 png
    private func makeFakeBundle(resources: [String: Data]) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuIconTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """
        try plist.data(using: .utf8)!.write(to: dir.appendingPathComponent("Info.plist"))
        for (name, data) in resources {
            try data.write(to: dir.appendingPathComponent("\(name).png"))
        }
        guard let bundle = Bundle(path: dir.path) else {
            throw XCTSkip("fake bundle 构造失败")
        }
        return bundle
    }

    // 发布版（SPM 构建手工拼 bundle，无 Assets.car）必须能从 Resources 的
    // menu_icon png 加载图标并完成 18pt 模板配置——否则运行时回落到系统符号，
    // 菜单栏显示的不是设计图标（CI 产物曾缺此资源导致该 bug）
    func testLoadMenuIconFromBareBundleResources() throws {
        // 用 NSBitmapImageRep 生成真 png 数据（NSImage(size:) 无 representation，
        // tiffRepresentation 会返回 nil）
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let pngData = rep.representation(using: .png, properties: [:])!
        let bundle = try makeFakeBundle(resources: ["menu_icon@2x": pngData])
        let image = StatusBarIcon.loadMenuIcon(in: bundle)
        XCTAssertNotNil(image, "裸 bundle 应能从 Resources 的 menu_icon png 加载")
        XCTAssertEqual(image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image?.isTemplate, true)
    }

    // bundle 无任何菜单栏图标资源时应返回 nil（调用方继续走系统符号 fallback）
    func testLoadMenuIconReturnsNilWhenResourceMissing() throws {
        let bundle = try makeFakeBundle(resources: [:])
        XCTAssertNil(StatusBarIcon.loadMenuIcon(in: bundle))
    }
}
