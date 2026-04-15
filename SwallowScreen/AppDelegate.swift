//
//  AppDelegate.swift
//  SwallowScreen
//
//  应用代理 - 处理托盘图标、菜单、窗口和快捷键
//

import AppKit
import SwiftUI
import SwiftData
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var modelContainer: ModelContainer?
    private var windowMover: WindowMover?
    private var settingsWindow: NSWindow?
    private var hotkeyObserver: Any?
    
    // 快捷键标识符
    private var setScreenHotKeyID = EventHotKeyID()
    private var clearScreenHotKeyID = EventHotKeyID()
    private var setScreenHotKeyRef: EventHotKeyRef?
    private var clearScreenHotKeyRef: EventHotKeyRef?
    
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
        
        // 设置全局快捷键
        setupGlobalHotKeys()
        
        // 监听设置窗口通知
        setupSettingsWindowObserver()
    }
    
    private func setupModelContainer() {
        let schema = Schema([AppInfo.self, AppSettings.self])
        
        let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwallowScreen")
        
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
            if let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "SwallowScreen") {
                image.isTemplate = true
                button.image = image
            } else {
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
        
        guard let container = modelContainer else {
            // 尝试重新创建
            setupModelContainer()
            guard let container = modelContainer else {
                print("Failed to create ModelContainer for popover")
                return
            }
            setupPopoverWithContainer(container)
            return
        }
        
        setupPopoverWithContainer(container)
    }
    
    private func setupPopoverWithContainer(_ container: ModelContainer) {
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
    
    private func setupSettingsWindowObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsWindow),
            name: .openSettingsWindow,
            object: nil
        )
    }
    
    private func setupWindowMover() {
        windowMover = WindowMover()
        if let container = modelContainer {
            windowMover?.configure(modelContext: container.mainContext)
            
            let descriptor = FetchDescriptor<AppSettings>()
            if let settings = try? container.mainContext.fetch(descriptor).first,
               settings.enableAutoMove {
                windowMover?.startMonitoring()
            }
        }
    }
    
    // MARK: - 全局快捷键设置
    private func setupGlobalHotKeys() {
        // 监听快捷键更新通知
        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .hotkeysUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.unregisterHotKeys()
            self?.registerHotKeys()
        }
        
        // 注册快捷键
        registerHotKeys()
    }
    
    private func registerHotKeys() {
        var setKeyCode: UInt32 = 0x18
        var setModifiers: UInt32 = UInt32(cmdKey | shiftKey)
        var clearKeyCode: UInt32 = 0x19
        var clearModifiers: UInt32 = UInt32(cmdKey | shiftKey)
        
        // 从设置读取快捷键配置
        if let container = modelContainer {
            let descriptor = FetchDescriptor<AppSettings>()
            if let settings = try? container.mainContext.fetch(descriptor).first {
                setKeyCode = UInt32(settings.setScreenKeyCode)
                setModifiers = settings.setScreenModifiers
                clearKeyCode = UInt32(settings.clearScreenKeyCode)
                clearModifiers = settings.clearScreenModifiers
            }
        }
        
        setScreenHotKeyID.signature = OSType(0x5357434E)
        setScreenHotKeyID.id = 1
        clearScreenHotKeyID.signature = OSType(0x5357434E)
        clearScreenHotKeyID.id = 2
        
        // 注册设置屏幕快捷键
        RegisterEventHotKey(setKeyCode, setModifiers, setScreenHotKeyID, GetApplicationEventTarget(), 0, &setScreenHotKeyRef)
        
        // 注册清除屏幕快捷键
        RegisterEventHotKey(clearKeyCode, clearModifiers, clearScreenHotKeyID, GetApplicationEventTarget(), 0, &clearScreenHotKeyRef)
        
        // 安装事件处理器
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        var handlerRef: EventHandlerRef?
        let handlerBlock: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            
            if hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    delegate.setCurrentAppScreen()
                }
            } else if hotKeyID.id == 2 {
                DispatchQueue.main.async {
                    delegate.clearCurrentAppScreen()
                }
            }
            return noErr
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), handlerBlock, 1, &eventSpec, selfPtr, &handlerRef)
    }
    
    private func unregisterHotKeys() {
        if let setHotKey = setScreenHotKeyRef {
            UnregisterEventHotKey(setHotKey)
            setScreenHotKeyRef = nil
        }
        if let clearHotKey = clearScreenHotKeyRef {
            UnregisterEventHotKey(clearHotKey)
            clearScreenHotKeyRef = nil
        }
    }
    
    // MARK: - 快捷键处理
    @objc private func setCurrentAppScreen() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }
        
        // 获取鼠标位置所在屏幕
        let mouseLocation = NSEvent.mouseLocation
        var targetScreen: NSScreen?
        
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                targetScreen = screen
                break
            }
        }
        
        // 如果鼠标不在任何屏幕上，使用前台窗口位置判断
        if targetScreen == nil {
            targetScreen = NSScreen.main
        }
        
        guard let screen = targetScreen else { return }
        
        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        
        // 保存配置
        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.bundleIdentifier == bundleID })
            
            if let existing = try? context.fetch(descriptor).first {
                existing.updateScreen(screenID: screenID, screenName: screen.localizedName)
            } else {
                let newInfo = AppInfo(
                    bundleIdentifier: bundleID,
                    appName: frontApp.localizedName ?? bundleID,
                    targetScreenID: screenID,
                    targetScreenName: screen.localizedName
                )
                context.insert(newInfo)
            }
            
            // 移动窗口到目标屏幕
            windowMover?.moveAppToScreen(bundleIdentifier: bundleID, screenID: screenID)
        }
    }
    
    @objc private func clearCurrentAppScreen() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }
        
        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.bundleIdentifier == bundleID })
            
            if let existing = try? context.fetch(descriptor).first {
                existing.updateScreen(screenID: nil, screenName: nil)
                existing.isEnabled = false
            }
        }
    }
    
    // MARK: - 设置窗口
    @objc private func openSettingsWindow() {
        // 关闭 popover
        closePopover()
        
        // 如果窗口已存在，先关闭再重新创建以确保居中
        if settingsWindow != nil {
            settingsWindow?.close()
            settingsWindow = nil
        }
        
        // 确保 modelContainer 存在
        guard let container = modelContainer else {
            // 尝试重新创建
            setupModelContainer()
            if modelContainer == nil {
                print("Failed to create ModelContainer")
                return
            }
            guard let container = modelContainer else { return }
            openSettingsWindowWithContainer(container)
            return
        }
        
        openSettingsWindowWithContainer(container)
    }
    
    private func openSettingsWindowWithContainer(_ container: ModelContainer) {
        let settingsView = SettingsView()
            .modelContainer(container)
        
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "SwallowScreen 设置"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        
        // 计算窗口大小并居中显示
        window.setContentSize(NSSize(width: 400, height: 480))
        window.center()
        
        settingsWindow = window
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        print("Screen configuration changed")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        windowMover?.stopMonitoring()
        
        // 注销快捷键观察者
        if let observer = hotkeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        
        // 注销快捷键
        unregisterHotKeys()
    }
}

// MARK: - NSWindowDelegate
extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == settingsWindow {
            settingsWindow = nil
        }
    }
}
