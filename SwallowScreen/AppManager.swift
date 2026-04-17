//
//  AppManager.swift
//  SwallowScreen
//
//  应用管理器 - 获取系统已安装应用列表
//

import Foundation
import AppKit
import Combine

struct SystemApp: Identifiable, Hashable {
    let id: String
    let bundleIdentifier: String
    let name: String
    let path: String
    let icon: NSImage?
    let isMenuBarApp: Bool  // 是否是菜单栏应用
    
    init(bundleIdentifier: String, name: String, path: String, icon: NSImage?, isMenuBarApp: Bool = false) {
        self.id = bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.icon = icon
        self.isMenuBarApp = isMenuBarApp
    }
}

@MainActor
class AppManager: ObservableObject {
    @Published var installedApps: [SystemApp] = []
    @Published var filteredApps: [SystemApp] = []
    @Published var searchText: String = "" {
        didSet {
            filterApps()
        }
    }
    
    init() {
        Task {
            await loadInstalledApps()
        }
    }
    
    func loadInstalledApps() async {
        var apps: [SystemApp] = []
        
        // 获取常见应用目录
        let applicationDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        
        for directory in applicationDirectories {
            await scanApplications(in: directory, apps: &apps)
        }
        
        // 去重并按名称排序
        var uniqueApps: [String: SystemApp] = [:]
        for app in apps {
            uniqueApps[app.bundleIdentifier] = app
        }
        
        self.installedApps = Array(uniqueApps.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.filteredApps = self.installedApps
    }
    
    private func scanApplications(in directory: URL, apps: inout [SystemApp]) async {
        let fileManager = FileManager.default
        
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }
        
        for item in contents {
            if item.pathExtension == "app" {
                if let bundle = Bundle(url: item),
                   let bundleIdentifier = bundle.bundleIdentifier {
                    let name = bundle.infoDictionary?["CFBundleName"] as? String 
                        ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? item.deletingPathExtension().lastPathComponent
                    
                    // 跳过系统应用和当前应用
                    if bundleIdentifier.contains("com.apple.") && !bundleIdentifier.contains("AppStore") {
                        continue
                    }
                    if bundleIdentifier == Bundle.main.bundleIdentifier {
                        continue
                    }
                    
                    // 检测是否是菜单栏应用 (LSUIElement = true)
                    let isMenuBarApp = (bundle.infoDictionary?["LSUIElement"] as? Bool) == true
                    
                    let icon = NSWorkspace.shared.icon(forFile: item.path)
                    icon.size = NSSize(width: 32, height: 32)
                    
                    let app = SystemApp(
                        bundleIdentifier: bundleIdentifier,
                        name: name,
                        path: item.path,
                        icon: icon,
                        isMenuBarApp: isMenuBarApp
                    )
                    apps.append(app)
                }
            }
        }
    }
    
    private func filterApps() {
        if searchText.isEmpty {
            filteredApps = installedApps
        } else {
            filteredApps = installedApps.filter { app in
                app.name.localizedCaseInsensitiveContains(searchText) ||
                app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    func getIconData(for app: SystemApp) -> Data? {
        guard let icon = app.icon else { return nil }
        if let tiffData = icon.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return pngData
        }
        return nil
    }
}
