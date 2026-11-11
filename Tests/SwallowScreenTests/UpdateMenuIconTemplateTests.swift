//
//  UpdateMenuIconTemplateTests.swift
//  SwallowScreenTests
//
//  菜单栏图标模板图契约测试（swift test 运行）
//  背景：MenuIcon png 曾导出为不透明背景，isTemplate 模板渲染按 alpha 蒙版
//  染色 → 整个 18pt 区域变纯色方块（状态栏白方块 bug 的根因）
//  直接验证仓库源 png（主模块 Assets.car 与 CI 发布版裸 png 均源于此）
//

import XCTest
import CoreGraphics
import ImageIO
@testable import SwallowScreenCore

final class UpdateMenuIconTemplateTests: XCTestCase {

    /// 定位仓库中的 MenuIcon 源 png（#filePath 向上三级 = package 根）
    private func sourcePNG(scale: String) throws -> URL {
        let pngURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SwallowScreenTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package 根
            .appendingPathComponent("SwallowScreen/Assets.xcassets/MenuIcon.imageset/menu_icon\(scale).png")
        try XCTAssertTrue(FileManager.default.fileExists(atPath: pngURL.path),
                          "未找到源资源 \(pngURL.path)")
        return pngURL
    }

    /// 解码 png 为 RGBA 像素
    private func loadPixels(scale: String) throws -> (width: Int, height: Int, data: [UInt8]) {
        let url = try sourcePNG(scale: scale)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, data)
    }

    // 契约：三张 scale 的 png 都必须是「图形不透明 + 背景全透明」的模板图——
    // 模板渲染按 alpha 蒙版染色，背景不透明会让整个 18pt 状态栏区域染成纯色方块
    func testMenuIconImagesHaveTransparentBackground() throws {
        for scale in ["", "@2x", "@3x"] {
            let (w, h, data) = try loadPixels(scale: scale)

            let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
            for (x, y) in corners {
                let a = data[(y * w + x) * 4 + 3]
                XCTAssertEqual(a, 0, "\(scale) 角落(\(x),\(y)) alpha=\(a)，背景未透明")
            }

            // 不透明像素占比必须明显小于全图（曾因 100% 不透明致方块）
            let opaque = data.indices.filter { $0 % 4 == 3 && data[$0] > 200 }.count / 4
            let ratio = Double(opaque) / Double(w * h)
            XCTAssertLessThan(ratio, 0.6, "\(scale) 不透明占比 \(Int(ratio * 100))%，疑似整图不透明")
        }
    }

    // 契约：图形主体（中心行）必须保留（透明化处理不能把图形一并清掉）
    func testMenuIconShapeIsPreserved() throws {
        for scale in ["", "@2x", "@3x"] {
            let (w, h, data) = try loadPixels(scale: scale)
            let centerRowOpaque = (0..<w).contains { x in
                data[(h / 2 * w + x) * 4 + 3] > 200
            }
            XCTAssertTrue(centerRowOpaque, "\(scale) 中心行无不透明像素，图形疑似丢失")
        }
    }
}
