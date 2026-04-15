//
//  AppDelegate.swift
//  SwallowScreen
//
//  应用代理 - 处理托盘图标和菜单
//

import AppKit
import SwiftUI
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var modelContainer: ModelContainer?
    private var windowMover: WindowMover?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 创建 ModelContainer
        setupModelContainer()
        
        // 创建状态栏图标
        setupStatusItem()
        
        // 创建弹出窗口
        setupPopover()
        
        // 监听屏幕变化
        setupScreenChangeObserver()
        
        // 初始化窗口移动器
        setupWindowMover()
    }
    
    private func setupModelContainer() {
        let schema = Schema([AppInfo.self, AppSettings.self])
        
        // 配置存储路径
        let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwallowScreen")
        
        // 创建目录（如果不存在）
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL.appendingPathComponent("SwallowScreen.store"),
            allowsSave: true
        )
        
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("ModelContainer creation failed: \(error)")
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // 使用 SF Symbols 图标
            if let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "SwallowScreen") {
                image.isTemplate = true
                button.image = image
            } else {
                // 备用图标
                button.title = "SS"
            }
            
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 360, height: 400)
        popover?.behavior = .transient
        popover?.animates = true
        
        // 使用已有的 ModelContainer
        guard let container = modelContainer else { return }
        
        let contentView = AppPopoverView()
            .modelContainer(container)
        
        popover?.contentViewController = NSHostingController(rootView: contentView)
    }
    
    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: .screenConfigurationChanged,
            object: nil
        )
    }
    
    private func setupWindowMover() {
        windowMover = WindowMover()
        if let container = modelContainer {
            windowMover?.configure(modelContext: container.mainContext)
            
            // 检查是否启用自动移动
            let descriptor = FetchDescriptor<AppSettings>()
            if let settings = try? container.mainContext.fetch(descriptor).first,
               settings.enableAutoMove {
                windowMover?.startMonitoring()
            }
        }
    }
    
    @objc private func togglePopover() {
        if let popover = popover {
            if popover.isShown {
                closePopover()
            } else {
                showPopover()
            }
        }
    }
    
    private func showPopover() {
        if let button = statusItem?.button {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // 监听点击外部事件
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                if self?.popover?.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }
    
    private func closePopover() {
        popover?.performClose(nil)
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
    
    @objc private func screenConfigurationChanged() {
        // 屏幕配置变化时刷新
        print("Screen configuration changed")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        windowMover?.stopMonitoring()
    }
}
