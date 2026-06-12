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
import os.log

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var appPopover: NSPopover?
    private var modelContainer: ModelContainer?
    private var windowMover: WindowMover?
    private var settingsWindow: NSWindow?
    private var hotkeyObserver: Any?
    private var permissionCheckTimer: DispatchSourceTimer? // 权限检查定时器
    // RT28: 三个 token-style observer，统一清理
    private var screenChangeObserverToken: Any?
    private var openSettingsObserverToken: Any?
    private var pinToScreenObserverToken: Any?
    // RT60: dark mode 切换监听
    private var appearanceObserverToken: Any?

    // P0-持久化: AppManager/ScreenManager 提升为 AppDelegate 级别持久对象
    // 之前：@StateObject 在 AppPopoverView 内，每次 popover 重建时重新创建
    //       AppManager.init() → 扫描 3 目录 + 200+ SystemApp 实例化 + 图标缓存重建
    //       每次打开 popover 峰值 +2-4MB，关闭后虽释放但 GC 不及时
    // 现在：AppDelegate 持有，popover 通过 @EnvironmentObject 注入，跨 popover 生命周期复用
    let appManager = AppManager()
    let screenManager = ScreenManager()
    
    // 快捷键标识符
    private var setScreenHotKeyID = EventHotKeyID()
    private var clearScreenHotKeyID = EventHotKeyID()
    private var setScreenHotKeyRef: EventHotKeyRef?
    private var clearScreenHotKeyRef: EventHotKeyRef?
    // T12: Carbon 事件 handler 引用，applicationWillTerminate 时显式释放
    private var hotKeyHandlerRef: EventHandlerRef?
    // T17: setupWindowMover 1s 延时的 DispatchWorkItem，可取消
    private var setupWindowMoverWorkItem: DispatchWorkItem?
    // T3: 标志位防止 setupWindowMover 重入
    private var isSettingUpWindowMover: Bool = false
    // R-154: windowDidMove/Resize 防抖——resize 期间一秒触发几十次，每次同步写 plist 卡 UI
    private var saveFrameWorkItem: DispatchWorkItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 创建 ModelContainer
        setupModelContainer()

        // 创建状态栏图标
        setupStatusItem()

        // RT60: 监听 dark/light mode 切换
        setupAppearanceObserver()

        // 监听屏幕变化
        setupScreenChangeObserver()

        // 设置全局快捷键
        setupGlobalHotKeys()

        // 监听设置窗口通知
        setupSettingsWindowObserver()

        // 初始化窗口管理器（最后初始化，确保 modelContainer 已准备好）
        // T17: 用可取消的 DispatchWorkItem 替代裸 asyncAfter
        let workItem = DispatchWorkItem { [weak self] in
            self?.setupWindowMover()
        }
        setupWindowMoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }
    
    private func setupModelContainer() {
        let schema = Schema([AppInfo.self, AppSettings.self])

        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            showCriticalAlert(title: "数据初始化失败", message: "找不到 Application Support 目录，应用无法保存配置。")
            return
        }
        let storeURL = appSupport.appendingPathComponent("SwallowScreen")

        do {
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        } catch {
            os_log("创建数据目录失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
            showCriticalAlert(title: "数据初始化失败", message: "无法创建数据目录：\(error.localizedDescription)")
            return
        }

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL.appendingPathComponent("SwallowScreen.store")
        )

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            os_log("ModelContainer 创建失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
            showCriticalAlert(title: "数据初始化失败", message: "无法创建数据容器：\(error.localizedDescription)\n请尝试重启应用或重装。")
            // R-187: fail-fast——modelContainer 为 nil 时后续 setup 全部跳过；
            //       不 return 会导致后续 setupStatusItem / setupAppearanceObserver / setupScreenChangeObserver
            //       / setupGlobalHotKeys 在 container 为 nil 的状态下静默工作，
            //       toggleAppWindow → initializePopover 又 silent return，用户点托盘图标无反应。
            //       与 line 86 catch 块已 return 风格一致
            return
        }
    }

    /// T19: 关键错误弹 NSAlert 告知用户，不再只 print 一行
    // R-227: 始终用 beginSheetModal / 非阻塞 show——runModal() 会阻塞主线程，
    //        导致窗口监控暂停（与 showSaveErrorAlert 的 R-154 修复同理）
    private func showCriticalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            // R-227: 无 keyWindow 时只能用 runModal()——NSAlert 没有 show() 方法
            //        beginSheetModal 需要关联 window；runModal() 虽然阻塞 RunLoop，
            //        但此路径仅在 keyWindow 为 nil 时触发（启动期/权限未授予），影响有限
            alert.runModal()
        }
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        applyStatusItemImage()
        button?.action = #selector(toggleAppWindow)
        button?.target = self
    }

    private var button: NSStatusBarButton? { statusItem?.button }

    /// RT60: 提取图标设置，方便 dark mode 切换时重设
    private func applyStatusItemImage() {
        guard let button = button else { return }
        if let image = NSImage(named: "MenuIcon") {
            image.isTemplate = true
            button.image = image
        } else if let image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "SwallowScreen") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "SS"
        }
    }

    /// RT60: 监听系统外观变化（dark/light mode 切换）
    // R-201: NSSystemColorsDidChangeNotification 已重命名为 NSColor.systemColorsDidChangeNotification
    private func setupAppearanceObserver() {
        appearanceObserverToken = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.applyStatusItemImage()
            }
        }
    }
    
    private func initializePopover() {
        guard let container = modelContainer else {
            setupModelContainer()
            guard modelContainer != nil else {
                return
            }
            setupPopoverWithContainer(modelContainer!)
            return
        }
        
        setupPopoverWithContainer(container)
    }
    
    private func setupPopoverWithContainer(_ container: ModelContainer) {
        // P0-持久化: 注入 AppDelegate 持有的 appManager/screenManager，
        // 避免 AppPopoverView 内 @StateObject 每次重建
        let contentView = AppPopoverView()
            .modelContainer(container)
            .environmentObject(appManager)
            .environmentObject(screenManager)

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
            // M1: 关闭后立即释放 contentViewController，
            // 切断 AppDelegate → NSPopover → NSHostingController → AppPopoverView 引用链
            // P0-持久化: AppManager/ScreenManager 已提升为 AppDelegate 持久对象，
            //     此处释放 contentViewController 不影响 appManager/screenManager
            popover.contentViewController = nil
            // P3: popover 关闭时取消正在进行的更新检查，避免 task 完成后回调已释放的 UI
            UpdateChecker.shared.cancel()
        } else {
            if appPopover == nil {
                initializePopover()
            } else if appPopover?.contentViewController == nil, let container = modelContainer {
                // M1: 重新 setup 之前释放的内容
                setupPopoverWithContainer(container)
            }
            if let popover = appPopover {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    
    private func setupScreenChangeObserver() {
        // RT28: 改用 token-style observer
        screenChangeObserverToken = NotificationCenter.default.addObserver(
            forName: .screenConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.windowMover?.triggerImmediateCheck()
            }
        }
    }

    private func setupSettingsWindowObserver() {
        // RT28: 改用 token-style observer
        openSettingsObserverToken = NotificationCenter.default.addObserver(
            forName: .openSettingsWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.openSettingsWindow()
            }
        }

        // RT28: 改用 token-style observer
        pinToScreenObserverToken = NotificationCenter.default.addObserver(
            forName: .pinToScreenChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.windowMover?.triggerImmediateCheck()
            }
        }
    }
    
    private func setupWindowMover() {
        // T3: 防止权限授予瞬间与初始延时的 setupWindowMover 重入
        if isSettingUpWindowMover { return }
        isSettingUpWindowMover = true
        defer { isSettingUpWindowMover = false }

        guard let container = modelContainer else { return }

        windowMover = WindowMover()
        windowMover?.configure(modelContext: container.mainContext)

        if windowMover?.startMonitoring() == true {
            // RT76: 改 cancel()——permissionCheckTimer 字段类型已在 RT59 改为 DispatchSourceTimer
            permissionCheckTimer?.cancel()
            permissionCheckTimer = nil
        } else {
            startPermissionCheckTimer()
        }
    }

    /// 启动权限检查定时器
    /// RT16: 30s 未授权则 invalidate 定时器并 os_log，避免无限循环
    /// RT59: 改用 DispatchSourceTimer，避免被主 RunLoop 的 tracking mode 阻塞
    private func startPermissionCheckTimer() {
        permissionCheckTimer?.cancel()

        let permissionCheckStart = Date()
        let maxPermissionCheckDuration: TimeInterval = 30.0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }
            if AXIsProcessTrusted() {
                timer.cancel()
                self.permissionCheckTimer = nil
                // RT52: stop + setup 同步执行，避免异步 stop 与同步 setup 顺序竞争
                self.windowMover?.stopMonitoring()
                self.setupWindowMover()
                return
            }
            // RT16: 30s 兜底
            if Date().timeIntervalSince(permissionCheckStart) > maxPermissionCheckDuration {
                timer.cancel()
                self.permissionCheckTimer = nil
                os_log("辅助功能权限 30s 内未授予，停止轮询。请在 系统设置 → 隐私与安全 → 辅助功能 中手动开启 SwallowScreen。", log: OSLog.default, type: .error)
                // R-135: 自动跳到系统设置 → 隐私与安全 → 辅助功能
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        timer.resume()
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
            guard let self else { return }
            Task { @MainActor in
                self.unregisterHotKeys()
                self.registerHotKeys()
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

        // RT84: 入口先 RemoveEventHandler 旧的——防止异常路径下 handler 重复注册
        //       导致 setCurrentAppScreen/clearCurrentAppScreen 被双触发
        if let existingHandler = hotKeyHandlerRef {
            RemoveEventHandler(existingHandler)
            hotKeyHandlerRef = nil
        }

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
        // R-156: 检查 OSStatus——失败时 os_log + 清 ref
        let setStatus = RegisterEventHotKey(setKeyCode, setModifiers, setScreenHotKeyID, GetApplicationEventTarget(), 0, &setScreenHotKeyRef)
        if setStatus != noErr {
            os_log("RegisterEventHotKey(set) failed: status=%d keyCode=0x%X",
                   log: OSLog.default, type: .error, Int(setStatus), setKeyCode)
            setScreenHotKeyRef = nil
        }

        // 注册清除屏幕快捷键
        // R-156: 同上
        let clearStatus = RegisterEventHotKey(clearKeyCode, clearModifiers, clearScreenHotKeyID, GetApplicationEventTarget(), 0, &clearScreenHotKeyRef)
        if clearStatus != noErr {
            os_log("RegisterEventHotKey(clear) failed: status=%d keyCode=0x%X",
                   log: OSLog.default, type: .error, Int(clearStatus), clearKeyCode)
            clearScreenHotKeyRef = nil
        }

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

        // R-156: 检查 InstallEventHandler 返回值
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handlerBlock, 1, &eventSpec, selfPtr, &handlerRef)
        if installStatus != noErr {
            os_log("InstallEventHandler failed: status=%d", log: OSLog.default, type: .error, Int(installStatus))
            hotKeyHandlerRef = nil
        }
        // T12: 持有 handlerRef 引用，applicationWillTerminate 中释放
        hotKeyHandlerRef = handlerRef
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
        // T12: 释放 Carbon 事件 handler
        if let handler = hotKeyHandlerRef {
            RemoveEventHandler(handler)
            hotKeyHandlerRef = nil
        }
    }
    
    // MARK: - 快捷键处理
    @objc private func setCurrentAppScreen() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }

        // R-164: 过滤自身——LSUIElement App 作为 frontmost 时可能是自己
        guard bundleID != Bundle.main.bundleIdentifier else { return }

        // 获取鼠标位置所在屏幕
        let mouseLocation = NSEvent.mouseLocation
        var targetScreen: NSScreen?

        // RT68: 用 visibleFrame 匹配（与 RT7 ScreenManager.screen(containing:) 统一坐标语义）
        for screen in NSScreen.screens {
            if screen.visibleFrame.contains(mouseLocation) {
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
        let screenSerialNumber = ScreenManager.serialNumber(for: screen)

        // 保存配置
        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.bundleIdentifier == bundleID })

            if let existing = try? context.fetch(descriptor).first {
                existing.updateScreen(screenID: screenID, screenName: screen.localizedName, screenSerialNumber: screenSerialNumber)
                // R-167: 用户主动 set 屏 = 重新启用屏幕规则——clear 之后 set 恢复 isEnabled
                //        与 updatePinToScreen 的 `if pinned && !isEnabled { isEnabled = true }` 对齐
                existing.isEnabled = true
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

            // RT41: save 失败时通过 NSAlert 反馈
            do {
                try context.save()
            } catch {
                os_log("setCurrentAppScreen save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
                Self.showSaveErrorAlert(error: error)
                return
            }

            // RT67: 走 earlyWindowCatcher 链路，复用 hide → move → unhide + 稳态校验 + 防回弹
            //       （原 moveAppToScreen 走 moveAppWindowsToScreen 老路径，无防闪烁）
            // R-216: windowMover 为 nil 时 os_log 提示——启动期 / 权限未授予窗口期不静默失败
            if let mover = windowMover {
                mover.moveAppToScreen(bundleIdentifier: bundleID, screenID: screenID, screenSerialNumber: screenSerialNumber)
            } else {
                os_log("setCurrentAppScreen: windowMover 未就绪，bundleID=%{public}@ 配置已落盘但窗口未移动（启动期或权限未授予）",
                       log: OSLog.default, type: .error, bundleID)
            }
        }
    }

    @objc private func clearCurrentAppScreen() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }

        // R-164: 过滤自身
        guard bundleID != Bundle.main.bundleIdentifier else { return }

        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.bundleIdentifier == bundleID })

            if let existing = try? context.fetch(descriptor).first {
                existing.updateScreen(screenID: nil, screenName: nil, screenSerialNumber: nil)
                existing.isEnabled = false

                // RT41: 同上
                do {
                    try context.save()
                } catch {
                    os_log("clearCurrentAppScreen save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
                    Self.showSaveErrorAlert(error: error)
                }
            }
        }
    }

    // RT41: 通用 SwiftData save 错误反馈
    // R-157: 改为 internal（默认）——AppPopoverView.updatePinToScreen 路径也要用
    // R-227: runModal() fallback 同步改为非阻塞——与 showCriticalAlert 保持一致
    static func showSaveErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法保存配置"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            // R-227: 无 keyWindow 时只能用 runModal()——NSAlert 没有 show() 方法
            alert.runModal()
        }
    }

    // MARK: - 设置窗口
    @objc private func openSettingsWindow() {
        // 关闭 popover
        appPopover?.performClose(nil)

        // RT75: 复用 settingsWindow；连续打开不重建
        // （已存在：makeKeyAndOrderFront + center；不存在：openSettingsWindowWithContainer 新建）
        if let existing = settingsWindow {
            // R-197: 不强制 center()——用户拖窗口到屏幕角落，关闭后下次开仍应保留上次的 frame 位置
            //        existing.frame 由 NSWindow 自身在 windowDidMove/windowDidResize 中写 UserDefaults 持久化
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // 确保 modelContainer 存在
        guard let container = tryEnsureModelContainer() else {
            // RT29: 统一改 os_log
            os_log("ModelContainer 创建失败，无法打开设置窗口", log: OSLog.default, type: .error)
            return
        }

        openSettingsWindowWithContainer(container)
    }

    // RT36: 抽离 modelContainer 重建逻辑
    private func tryEnsureModelContainer() -> ModelContainer? {
        if let existing = modelContainer {
            return existing
        }
        setupModelContainer()
        // RT39: 若 modelContainer 重建成功，同步配置给 windowMover
        if let container = modelContainer {
            windowMover?.configure(modelContext: container.mainContext)
        }
        return modelContainer
    }

    // RT43: 设置窗口 frame UserDefaults key
    private static let settingsWindowFrameKey = "settingsWindowFrame"

    private func openSettingsWindowWithContainer(_ container: ModelContainer) {
        let settingsView = SettingsView()
            .modelContainer(container)

        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "SwallowScreen 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self

        // R-195: 删除死代码 setContentSize——与 SettingsView.body.frame(width: 480, height: 450) 不一致，
        //        SwiftUI 自身 frame 决定窗口大小；保留也无害但易误导后续维护
        // window.setContentSize(NSSize(width: 400, height: 400))
        // RT43: 若上次记住的 frame 存在则恢复
        if let frameString = UserDefaults.standard.string(forKey: Self.settingsWindowFrameKey) {
            let savedFrame = NSRectFromString(frameString)
            if savedFrame.width > 0 && savedFrame.height > 0 {
                window.setFrame(savedFrame, display: true)
            } else {
                window.center()
            }
        } else {
            window.center()
        }

        settingsWindow = window

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // T17: 取消未触发的 setupWindowMover 延时
        setupWindowMoverWorkItem?.cancel()
        setupWindowMoverWorkItem = nil

        // 停止权限检查定时器
        permissionCheckTimer?.cancel()
        permissionCheckTimer = nil

        // RT37: 显式调用 stopMonitoring，避开 ARC 释放链不确定性
        windowMover?.stopMonitoring()
        windowMover = nil

        // RT72: 移除 applicationWillTerminate 内 frame 写回——windowWillClose 已覆盖正常关闭路径
        // 崩溃/被 kill 场景可接受丢失最近一次 frame 调整

        // RT28: 注销所有 observer
        removeAllObservers()

        // 注销快捷键（包含 T12 handler 释放）
        unregisterHotKeys()

        // R-154: 取消 pending frame save 并立即写一次——避免最后一次 resize 调整丢失
        // R-219: 走 flushPendingFrameSave helper——与 windowWillClose 路径共用同一函数，消除重复
        if let window = settingsWindow {
            flushPendingFrameSave(window: window)
        }
    }

    // P3: deinit 兜底——applicationWillTerminate 之外（如 crash / 异常退出）也清理 observer
    // 之前：仅 applicationWillTerminate 清理；crash 路径下 observer token 残留，下次启动可能误触发
    // 注：deinit 是 nonisolated，不能调 @MainActor 方法；直接内联清理逻辑
    deinit {
        if let observer = hotkeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let token = screenChangeObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = openSettingsObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = pinToScreenObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = appearanceObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// 集中清理所有 NotificationCenter observer——deinit 与 applicationWillTerminate 共用
    private func removeAllObservers() {
        if let observer = hotkeyObserver {
            NotificationCenter.default.removeObserver(observer)
            hotkeyObserver = nil
        }
        if let token = screenChangeObserverToken {
            NotificationCenter.default.removeObserver(token)
            screenChangeObserverToken = nil
        }
        if let token = openSettingsObserverToken {
            NotificationCenter.default.removeObserver(token)
            openSettingsObserverToken = nil
        }
        if let token = pinToScreenObserverToken {
            NotificationCenter.default.removeObserver(token)
            pinToScreenObserverToken = nil
        }
        if let token = appearanceObserverToken {
            NotificationCenter.default.removeObserver(token)
            appearanceObserverToken = nil
        }
    }
}

// MARK: - NSWindowDelegate
// R-202: class declaration 已有 NSWindowDelegate conform (line 15)，extension 重复声明会触发
//        `redundant conformance` 错误（Swift 5 warning / Swift 6 error）
extension AppDelegate {
    // RT66: 实时写 settingsWindow frame 到 UserDefaults
    // R-154: 走 0.5s 防抖——resize 期间一秒触发几十次，每次同步写 plist 会卡 UI
    func windowDidMove(_ notification: Notification) {
        saveSettingsWindowFrameDebounced(from: notification.object as? NSWindow)
    }

    func windowDidResize(_ notification: Notification) {
        saveSettingsWindowFrameDebounced(from: notification.object as? NSWindow)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            // R-154: 立即写一次（取消 pending 防抖），确保关闭前 frame 已落盘
            flushPendingFrameSave(window: window)
            // RT61: 解除反向引用
            if window == settingsWindow {
                window.delegate = nil
                settingsWindow = nil
            }
        }
    }

    /// R-154: 防抖——0.5s 内的多次 move/resize 只触发一次写盘
    private func saveSettingsWindowFrameDebounced(from window: NSWindow?) {
        guard let window = window, window == settingsWindow else { return }
        saveFrameWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.writeSettingsWindowFrame(window: window)
        }
        saveFrameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// R-154: 取消 pending 防抖并立即同步写一次
    // R-221: 不再检查 window == settingsWindow——windowWillClose 已把 settingsWindow 置 nil，
    //        但 frame 写入不应依赖此引用；applicationWillTerminate 中调用时窗口可能已 close
    private func flushPendingFrameSave(window: NSWindow) {
        saveFrameWorkItem?.cancel()
        saveFrameWorkItem = nil
        writeSettingsWindowFrame(window: window)
    }

    /// R-154: 实际写盘（防抖落地点 / 立即写共用）
    // R-221: 仅检查窗口有效性（frame > 0），不再依赖 settingsWindow 引用——
    //        windowWillClose 中 settingsWindow 已被置 nil，但 frame 仍应写入
    private func writeSettingsWindowFrame(window: NSWindow) {
        let frame = window.frame
        guard frame.width > 0 && frame.height > 0 else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.settingsWindowFrameKey)
    }
}
