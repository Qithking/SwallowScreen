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
        // 不创建 WindowGroup，因为我们使用 Menu Bar App
        Settings {
            Text("SwallowScreen")
        }
    }
}
