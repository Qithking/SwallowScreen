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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var appPopover: NSPopover?
    private var modelContainer: ModelContainer?
    private var windowMover: WindowMover?
    private var settingsWindow: NSWindow?
    private var hotkeyObserver: Any?
    private var permissionCheckTimer: Timer? // 权限检查定时器
    
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
        
        // 监听屏幕变化
        setupScreenChangeObserver()
        
        // 设置全局快捷键
        setupGlobalHotKeys()
        
        // 监听设置窗口通知
        setupSettingsWindowObserver()
        
        // 初始化窗口管理器（最后初始化，确保 modelContainer 已准备好）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.setupWindowMover()
        }
    }
    
    private func setupModelContainer() {
        let schema = Schema([AppInfo.self, AppSettings.self])
        
        let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwallowScreen")
        
        try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL.appendingPathComponent("SwallowScreen.store")
        )
        
        modelContainer = try? ModelContainer(for: schema, configurations: [modelConfiguration])
        
        if modelContainer == nil {
            print("ModelContainer creation failed")
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
            
            button.action = #selector(toggleAppWindow)
            button.target = self
        }
    }
    
    private func initializePopover() {
        guard let container = modelContainer else {
            setupModelContainer()
            guard let container = modelContainer else {
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
        
        let hostingController = NSHostingController(rootView: contentView)
        
        let popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        
        appPopover = popover
    }
    
    @objc private func toggleAppWindow() {
        guard let button = statusItem?.button else { return }
        
        if let popover = appPopover, popover.isShown {
            popover.performClose(nil)
        } else {
            if appPopover == nil {
                initializePopover()
            }
            if let popover = appPopover {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
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
        
        // 监听固定屏幕变化通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pinToScreenChanged),
            name: .pinToScreenChanged,
            object: nil
        )
    }
    
    @objc private func pinToScreenChanged() {
        // 立即触发窗口位置检查
        Task { @MainActor in
            windowMover?.triggerImmediateCheck()
        }
    }
    
    private func setupWindowMover() {
        guard let container = modelContainer else { return }
        
        windowMover = WindowMover()
        windowMover?.configure(modelContext: container.mainContext)
        
        if windowMover?.startMonitoring() == true {
            permissionCheckTimer?.invalidate()
            permissionCheckTimer = nil
        } else {
            startPermissionCheckTimer()
        }
    }
    
    /// 停止 WindowMover 监控
    private func stopWindowMoverMonitoring() {
        Task { @MainActor in
            self.windowMover?.stopMonitoring()
        }
    }
    
    /// 启动权限检查定时器
    private func startPermissionCheckTimer() {
        permissionCheckTimer?.invalidate()
        
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                Task { @MainActor [weak self] in
                    self?.stopWindowMoverMonitoring()
                    self?.setupWindowMover()
                }
            }
        }
        permissionCheckTimer = timer
    }
    
    // MARK: - 全局快捷键设置
    private func setupGlobalHotKeys() {
        // 监听快捷键更新通知
        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .hotkeysUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.unregisterHotKeys()
                self?.registerHotKeys()
            }
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
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerBlock: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            
            if hotKeyID.id == 1 {
                Task { @MainActor in
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                    delegate.setCurrentAppScreen()
                }
            } else if hotKeyID.id == 2 {
                Task { @MainActor in
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                    delegate.clearCurrentAppScreen()
                }
            }
            return noErr
        }
        
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
        let screenSerialNumber = getScreenSerialNumber(for: screen)
        
        // 保存配置
        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.bundleIdentifier == bundleID })
            
            if let existing = try? context.fetch(descriptor).first {
                existing.updateScreen(screenID: screenID, screenName: screen.localizedName, screenSerialNumber: screenSerialNumber)
            } else {
                let newInfo = AppInfo(
                    bundleIdentifier: bundleID,
                    appName: frontApp.localizedName ?? bundleID,
                    targetScreenID: screenID,
                    targetScreenName: screen.localizedName,
                    targetScreenSerialNumber: screenSerialNumber
                )
                context.insert(newInfo)
            }
            
            // 确保数据被保存
            try? context.save()
            
            // 移动窗口到目标屏幕
            windowMover?.moveAppToScreen(bundleIdentifier: bundleID, screenID: screenID, screenSerialNumber: screenSerialNumber)
        }
    }
    
    @objc private func clearCurrentAppScreen() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }
        
        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.bundleIdentifier == bundleID })
            
            if let existing = try? context.fetch(descriptor).first {
                existing.updateScreen(screenID: nil, screenName: nil, screenSerialNumber: nil)
                existing.isEnabled = false
                
                // 确保数据被保存
                try? context.save()
            }
        }
    }
    
    /// 获取屏幕序列号
    /// 使用序列号 > vendor-model 组合作为屏幕唯一标识
    private func getScreenSerialNumber(for screen: NSScreen) -> String? {
        guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              screenID != 0 else {
            return nil
        }
        
        // 获取屏幕序列号
        let serialNumber = CGDisplaySerialNumber(screenID)
        
        // 如果有有效序列号，优先使用
        if serialNumber != 0 {
            return "SN:\(serialNumber)"
        }
        
        // 否则使用 vendor + model 组合（显示器通常有这两个 ID）
        let vendorID = CGDisplayVendorNumber(screenID)
        let modelID = CGDisplayModelNumber(screenID)
        
        // vendor 为 0 表示无法识别该显示器
        if vendorID != 0 {
            return "VM:\(vendorID)-\(modelID)"
        }
        
        // 最后使用 displayID 作为标识（这是最不稳定的，但聊胜于无）
        return "ID:\(screenID)"
    }
    
    // MARK: - 设置窗口
    @objc private func openSettingsWindow() {
        // 关闭 popover
        appPopover?.performClose(nil)
        
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
        window.isReleasedWhenClosed = false
        window.delegate = self
        
        // 计算窗口大小并居中显示
        window.setContentSize(NSSize(width: 400, height: 400))
        window.center()
        
        settingsWindow = window
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func screenConfigurationChanged() {
        // 屏幕配置变化时的处理
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // 停止权限检查定时器
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
        
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
        if let window = notification.object as? NSWindow {
            if window == settingsWindow {
                settingsWindow = nil
            }
        }
    }
}
