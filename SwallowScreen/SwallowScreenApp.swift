//
//  SwallowScreenApp.swift
//  SwallowScreen
//
//  应用入口 - Menu Bar App (LSUIElement)
//

import SwiftUI
import SwiftData

@main
struct SwallowScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // RT35: 占位 Settings scene 改为 EmptyView，避免 Cmd+, 弹出"SwallowScreen"空窗
        // AppDelegate 自身处理菜单栏图标与自定义设置窗口
        Settings {
            EmptyView()
        }
    }
}
