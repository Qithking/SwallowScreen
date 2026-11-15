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
        // Settings scene 仅作 SceneBuilder 占位（EmptyView），不能删除；
        // Cmd+, 已由 AppDelegate 的 installCmdCommaMonitor 拦截并转发到自定义
        // 设置窗口（openSettingsWindow），系统默认打开此 scene 的路径不会触发，
        // 避免弹出空白设置窗。AppDelegate 自身处理菜单栏图标
        Settings {
            EmptyView()
        }
    }
}
