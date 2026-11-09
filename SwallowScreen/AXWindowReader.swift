//
//  AXWindowReader.swift
//  SwallowScreen
//
//  AX 属性读取入口。
//  约定：调用成功且值类型匹配才返回解包值，否则返回 nil（类型不符不强转，避免崩溃）。
//

import AppKit
import CoreGraphics

enum AXWindowReader {

    // MARK: - 基础读取

    /// 读取任意属性原始值（成功且非 nil 才返回）
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
            return nil
        }
        return raw
    }

    /// 读取字符串属性（title/subrole 等）
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        return value(element, attribute) as? String
    }

    /// 读取布尔属性（AXFullScreen/AXMain 等）
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        return value(element, attribute) as? Bool
    }

    /// 读取子元素属性（缩放按钮等）
    /// 注：CF 类型无条件转换（AX 保证成功时返回对应元素类型），nil 由调用成功性保证
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute) else { return nil }
        return (raw as! AXUIElement) as AXUIElement
    }

    // MARK: - 几何读取（AX 使用 TL 坐标系，Y 向下）

    /// 读取窗口位置
    /// 注：CF 类型的 as? 恒成功，真实类型校验由 AXValueGetValue 返回值承担
    static func position(_ element: AXUIElement) -> CGPoint? {
        guard let raw = value(element, kAXPositionAttribute as String) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// 读取窗口尺寸
    static func size(_ element: AXUIElement) -> CGSize? {
        guard let raw = value(element, kAXSizeAttribute as String) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// 一次读取位置+尺寸（两属性都成功才返回）
    static func bounds(_ element: AXUIElement) -> CGRect? {
        guard let position = position(element), let size = size(element) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// 窗口是否仍可访问（位置属性可读即为"活着"，可用于 hide 前校验）
    static func isAlive(_ window: AXUIElement) -> Bool {
        return position(window) != nil
    }

    // MARK: - 应用窗口列表

    /// 读取应用元素的全部窗口列表
    static func windows(ofApplication appElement: AXUIElement) -> [AXUIElement]? {
        return value(appElement, kAXWindowsAttribute as String) as? [AXUIElement]
    }

    /// 按 pid 创建应用元素并读取窗口列表
    static func windows(pid: pid_t) -> [AXUIElement]? {
        return windows(ofApplication: AXUIElementCreateApplication(pid))
    }
}
