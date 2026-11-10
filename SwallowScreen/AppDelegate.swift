//
//  AppDelegate.swift
//  SwallowScreen
//
//  应用代理 - 处理托盘图标、菜单、窗口和快捷键
//

import AppKit
import SwiftUI
import SwiftData
import Combine
import Carbon.HIToolbox
import os.log
// SPM 构建下 PanelGeometry 位于 SwallowScreenCore 模块；Xcode 工程为平面 target 无需 import
#if canImport(SwallowScreenCore)
import SwallowScreenCore
#endif

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    // 菜单面板：无边框 NSPanel 替代 NSPopover——拖拽 resize 走窗口系统原生路径
    //（与拖 Finder 窗口边缘同机制，完全跟手零闪动），不再需要自定义拖拽逻辑
    private var appPanel: NSPanel?
    private var modelContainer: ModelContainer?
    private var windowMover: WindowMover?
    private var settingsWindow: NSWindow?
    private var hotkeyObserver: Any?
    private var permissionCheckTimer: DispatchSourceTimer?
    private var screenChangeObserverToken: Any?
    private var openSettingsObserverToken: Any?
    private var pinToScreenObserverToken: Any?
    private var appearanceObserverToken: Any?
    private var closePanelObserverToken: Any?
    // 点击面板外（其他应用）关闭面板的全局鼠标监听，模拟 NSPopover.transient 行为
    private var outsideClickMonitor: Any?

    // AppManager/ScreenManager 由 AppDelegate 持有，避免每次面板重建时重新扫描目录、重建图标缓存（峰值 +2-4MB 内存抖动）
    let appManager = AppManager()
    let screenManager = ScreenManager()
    
    private var setScreenHotKeyID = EventHotKeyID()
    private var clearScreenHotKeyID = EventHotKeyID()
    private var setScreenHotKeyRef: EventHotKeyRef?
    private var clearScreenHotKeyRef: EventHotKeyRef?
    // Carbon 事件 handler 引用，applicationWillTerminate 时显式释放
    private var hotKeyHandlerRef: EventHandlerRef?
    // setupWindowMover 1s 延时的 DispatchWorkItem，可取消
    private var setupWindowMoverWorkItem: DispatchWorkItem?
    // 防止 setupWindowMover 重入
    private var isSettingUpWindowMover: Bool = false
    // windowDidMove/Resize 防抖——resize 期间一秒触发几十次，同步写 plist 卡 UI
    private var saveFrameWorkItem: DispatchWorkItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupModelContainer()
        setupStatusItem()
        setupAppearanceObserver()
        setupScreenChangeObserver()
        setupGlobalHotKeys()
        setupSettingsWindowObserver()
        setupOutsideClickMonitor()

        // 初始化窗口管理器（最后初始化，确保 modelContainer 已就绪）；
        // 用可取消的 DispatchWorkItem，便于终止时撤销
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
            // fail-fast：modelContainer 为 nil 时，后续各 setup 会在无效状态下静默工作
            //（toggleAppWindow → initializePopover 静默 return，用户点托盘图标无反应）
            return
        }
    }

    /// 关键错误弹 NSAlert 告知用户
    // 用 beginSheetModal / 非阻塞弹窗——runModal() 会阻塞主线程，导致窗口监控暂停
    private func showCriticalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            // 无 keyWindow 时只能用 runModal()（beginSheetModal 需要关联窗口）；
            // 此路径仅在启动期/权限未授予时触发，阻塞影响有限
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

    /// 提取图标设置，方便 dark mode 切换时重设
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

    /// 监听系统外观变化（dark/light mode 切换）
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
    
    // MARK: - 菜单面板（NSPanel）

    private func setupOutsideClickMonitor() {
        // 全局鼠标按下（其他应用的事件）：点击处必在面板外（面板属本应用），直接关闭。
        // 本应用内点击由 windowDidResignKey 覆盖；handler 经 Task 回主线程操作 UI
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideAppPanel()
            }
        }
    }

    private func makeAppPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelGeometry.panelWidth, height: PanelGeometry.defaultHeight),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // fullSizeContentView + 隐藏标题栏：保留系统圆角/阴影，视觉与原 popover 一致；
        // 红绿灯按钮不适用于菜单面板（关闭即点击面板外/esc），逐一隐藏
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // 面板实例跨显示复用，关闭仅 orderOut，不释放
        panel.isReleasedWhenClosed = false
        // nonactivatingPanel 不抢焦点；面板内 TextField 仍可正常聚焦输入
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 宽度锁定 360（spec：仅高度可调），高度范围 400-800 与 clamp 逻辑一致
        panel.contentMinSize = NSSize(width: PanelGeometry.panelWidth, height: PanelGeometry.minHeight)
        panel.contentMaxSize = NSSize(width: PanelGeometry.panelWidth, height: PanelGeometry.maxHeight)
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        return panel
    }

    private func makePanelContent(container: ModelContainer) -> some View {
        AppPopoverView()
            .modelContainer(container)
            .environmentObject(appManager)
            .environmentObject(screenManager)
    }

    private func showAppPanel() {
        guard let container = tryEnsureModelContainer() else { return }
        let panel = appPanel ?? makeAppPanel()
        appPanel = panel

        // 恢复持久化高度（clamp 兜底），再定位到状态项按钮下方
        restoreAppPanelHeight(panel)
        // 每次显示重建 hostingView：保证 SwiftUI onAppear 触发
        //（搜索重置、屏幕刷新、欢迎提示、自动检查更新均依赖 onAppear）
        panel.contentView = NSHostingView(rootView: makePanelContent(container: container))
        positionAppPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        // 面板成为 key 后清掉初始键盘焦点（否则焦点环落在工具栏按钮上）；
        // 搜索框聚焦由用户点击触发，不受影响
        panel.makeFirstResponder(nil)
    }

    private func hideAppPanel() {
        guard let panel = appPanel, panel.isVisible else { return }
        persistAppPanelHeight(panel.frame.height)
        panel.orderOut(nil)
        // 面板关闭时取消正在进行的更新检查，避免回调后操作已移除的 UI
        UpdateChecker.shared.cancel()
    }

    /// 状态项按钮的屏幕坐标 frame 及其所在屏（菜单栏在哪块屏即哪块屏）；
    /// 面板水平定位与高度 clamp 统一以该屏为基准，按钮信息缺失时 screen 为 nil
    private var appPanelButtonLayout: (frame: NSRect, screen: NSScreen?)? {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return nil }
        let frame = buttonWindow.convertToScreen(button.frame)
        let screen = NSScreen.screens.first { $0.frame.contains(frame.origin) } ?? NSScreen.main
        return (frame, screen)
    }

    /// 从持久化设置恢复面板高度（设置缺失/脏数据时经 PanelGeometry 兜底）
    private func restoreAppPanelHeight(_ panel: NSPanel) {
        var persisted: Double?
        // try? 可接受：fetch 失败仅回退默认高度，与 persistAppPanelHeight 同口径
        if let container = modelContainer,
           let settings = try? container.mainContext.fetch(FetchDescriptor<AppSettings>()).first {
            persisted = settings.popoverHeight
        }
        // 高度 clamp 以按钮所在屏为准（面板显示在哪块屏就受哪块屏约束），取不到回退上限
        let visibleHeight = appPanelButtonLayout?.screen?.visibleFrame.height ?? PanelGeometry.maxHeight
        let height = PanelGeometry.restoredHeight(persisted: persisted, screenVisibleHeight: visibleHeight)
        panel.setContentSize(NSSize(width: PanelGeometry.panelWidth, height: height))
    }

    /// 面板定位到状态项按钮正下方，水平 clamp 在按钮所在屏的可见区域内
    private func positionAppPanel(_ panel: NSPanel) {
        guard let layout = appPanelButtonLayout, let screen = layout.screen else { return }
        let visible = screen.visibleFrame
        let x = min(max(layout.frame.minX, visible.minX),
                    max(visible.minX, visible.maxX - panel.frame.width))
        let y = layout.frame.minY - panel.frame.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 拖拽结束/面板关闭时写回持久化高度（与旧 NSPopover 实现同一 AppSettings 字段）
    private func persistAppPanelHeight(_ height: CGFloat) {
        guard let container = modelContainer else { return }
        // 保存同样以按钮所在屏 clamp，把小屏上拖出的超屏高度挡在入库前
        let visibleHeight = appPanelButtonLayout?.screen?.visibleFrame.height ?? PanelGeometry.maxHeight
        let clamped = PanelGeometry.clampHeight(height, screenVisibleHeight: visibleHeight)
        let descriptor = FetchDescriptor<AppSettings>()
        guard let settings = try? container.mainContext.fetch(descriptor).first else { return }
        settings.popoverHeight = Double(clamped)
        // 与 AppPopoverView.updateSetting 同口径：非关键路径 try? 可接受
        try? container.mainContext.save()
    }

    @objc private func toggleAppWindow() {
        if let panel = appPanel, panel.isVisible {
            hideAppPanel()
        } else {
            showAppPanel()
        }
    }
    
    private func setupScreenChangeObserver() {
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

        // esc 关闭面板（SwiftUI onExitCommand 发出，替代 popover 内建 esc 行为）
        closePanelObserverToken = NotificationCenter.default.addObserver(
            forName: .closeAppPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.hideAppPanel()
            }
        }
    }
    
    private func setupWindowMover() {
        // 防止权限授予瞬间与初始延时的 setupWindowMover 重入
        if isSettingUpWindowMover { return }
        isSettingUpWindowMover = true
        defer { isSettingUpWindowMover = false }

        guard let container = modelContainer else { return }

        windowMover = WindowMover(screenManager: screenManager)
        windowMover?.configure(modelContext: container.mainContext)

        if windowMover?.startMonitoring() == true {
            permissionCheckTimer?.cancel()
            permissionCheckTimer = nil
        } else {
            startPermissionCheckTimer()
        }
    }

    /// 启动权限检查定时器；30s 未授权则停止轮询，避免无限循环
    /// 用 DispatchSourceTimer，避免被主 RunLoop 的 tracking mode 阻塞
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
                // 同步先 stop 再 setup，保证执行顺序
                self.windowMover?.stopMonitoring()
                self.setupWindowMover()
                return
            }
            if Date().timeIntervalSince(permissionCheckStart) > maxPermissionCheckDuration {
                timer.cancel()
                self.permissionCheckTimer = nil
                os_log("辅助功能权限 30s 内未授予，停止轮询。请在 系统设置 → 隐私与安全 → 辅助功能 中手动开启 SwallowScreen。", log: OSLog.default, type: .error)
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

        registerHotKeys()
    }
    
    private func registerHotKeys() {
        var setKeyCode: UInt32 = 0x18
        var setModifiers: UInt32 = UInt32(cmdKey | shiftKey)
        var clearKeyCode: UInt32 = 0x19
        var clearModifiers: UInt32 = UInt32(cmdKey | shiftKey)

        // 先移除旧 handler，防止异常路径下重复注册导致
        // setCurrentAppScreen/clearCurrentAppScreen 被双触发
        if let existingHandler = hotKeyHandlerRef {
            RemoveEventHandler(existingHandler)
            hotKeyHandlerRef = nil
        }

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

        let setStatus = RegisterEventHotKey(setKeyCode, setModifiers, setScreenHotKeyID, GetApplicationEventTarget(), 0, &setScreenHotKeyRef)
        if setStatus != noErr {
            os_log("RegisterEventHotKey(set) failed: status=%d keyCode=0x%X",
                   log: OSLog.default, type: .error, Int(setStatus), setKeyCode)
            setScreenHotKeyRef = nil
        }

        let clearStatus = RegisterEventHotKey(clearKeyCode, clearModifiers, clearScreenHotKeyID, GetApplicationEventTarget(), 0, &clearScreenHotKeyRef)
        if clearStatus != noErr {
            os_log("RegisterEventHotKey(clear) failed: status=%d keyCode=0x%X",
                   log: OSLog.default, type: .error, Int(clearStatus), clearKeyCode)
            clearScreenHotKeyRef = nil
        }

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

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handlerBlock, 1, &eventSpec, selfPtr, &handlerRef)
        if installStatus != noErr {
            os_log("InstallEventHandler failed: status=%d", log: OSLog.default, type: .error, Int(installStatus))
            hotKeyHandlerRef = nil
        }
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
        if let handler = hotKeyHandlerRef {
            RemoveEventHandler(handler)
            hotKeyHandlerRef = nil
        }
    }
    
    // MARK: - 快捷键处理
    @objc private func setCurrentAppScreen() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }

        // 过滤自身——LSUIElement App 作为 frontmost 时可能是自己
        guard bundleID != Bundle.main.bundleIdentifier else { return }

        let mouseLocation = NSEvent.mouseLocation
        var targetScreen: NSScreen?

        // 用 visibleFrame 匹配，与 ScreenManager.screen(containing:) 保持一致
        for screen in NSScreen.screens {
            if screen.visibleFrame.contains(mouseLocation) {
                targetScreen = screen
                break
            }
        }

        // 鼠标不在任何屏幕上时回退主屏
        if targetScreen == nil {
            targetScreen = NSScreen.main
        }

        guard let screen = targetScreen else { return }

        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        let screenSerialNumber = ScreenManager.serialNumber(for: screen)

        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.bundleIdentifier == bundleID })

            // fetch 失败（Store 异常）必须与「记录不存在」区分，否则同 bundleID 会产生重复记录
            let existing: AppInfo?
            do {
                existing = try context.fetch(descriptor).first
            } catch {
                os_log("setCurrentAppScreen fetch 失败: %{public}@（bundleID=%{public}@，跳过本次保存）",
                       log: OSLog.default, type: .error, error.localizedDescription, bundleID)
                return
            }

            var titlePattern: String? = nil
            if let existing = existing {
                existing.updateScreen(screenID: screenID, screenName: screen.localizedName, screenSerialNumber: screenSerialNumber)
                // 用户主动 set 屏时重新启用屏幕规则（与 updatePinToScreen 的启用逻辑一致）
                existing.isEnabled = true
                titlePattern = existing.windowTitlePattern
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

            do {
                try context.save()
                // 通知 WindowMover 刷新缓存和 pinObserver
                NotificationCenter.default.post(name: .pinToScreenChanged, object: nil)
            } catch {
                os_log("setCurrentAppScreen save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
                Self.showSaveErrorAlert(error: error)
                return
            }

            // 走 earlyWindowCatcher 链路：hide → move → unhide + 稳态校验 + 防回弹
            if let mover = windowMover {
                mover.moveAppToScreen(bundleIdentifier: bundleID, screenID: screenID, screenSerialNumber: screenSerialNumber, titlePattern: titlePattern)
            } else {
                os_log("setCurrentAppScreen: windowMover 未就绪，bundleID=%{public}@ 配置已落盘但窗口未移动（启动期或权限未授予）",
                       log: OSLog.default, type: .error, bundleID)
            }
        }
    }

    @objc private func clearCurrentAppScreen() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else { return }

        // 过滤自身
        guard bundleID != Bundle.main.bundleIdentifier else { return }

        if let container = modelContainer {
            let context = container.mainContext
            let descriptor = FetchDescriptor<AppInfo>(predicate: #Predicate { $0.bundleIdentifier == bundleID })

            if let existing = try? context.fetch(descriptor).first {
                existing.updateScreen(screenID: nil, screenName: nil, screenSerialNumber: nil)
                // 清屏时同步关闭 pinToScreen——pin 需要目标屏幕才有意义，
                // 否则 pinToScreen=true 但无目标屏幕是无效状态
                if existing.pinToScreen {
                    existing.updatePinToScreen(false)
                }
                existing.isEnabled = false

                do {
                    try context.save()
                    // 通知 WindowMover 刷新缓存和 pinObserver
                    NotificationCenter.default.post(name: .pinToScreenChanged, object: nil)
                } catch {
                    os_log("clearCurrentAppScreen save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
                    Self.showSaveErrorAlert(error: error)
                }
            }
        }
    }

    // 通用 SwiftData save 错误反馈；AppPopoverView.updatePinToScreen 路径也调用
    static func showSaveErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法保存配置"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            // 无 keyWindow 时只能用 runModal()（beginSheetModal 需要关联窗口）
            alert.runModal()
        }
    }

    // MARK: - 设置窗口
    @objc private func openSettingsWindow() {
        // 打开设置窗口前先收起面板（原 popover 关闭行为）
        hideAppPanel()

        if let existing = settingsWindow {
            // 不强制 center()：保留用户上次调整的窗口位置
            //（frame 已由 windowDidMove/Resize 写 UserDefaults 持久化）
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let container = tryEnsureModelContainer() else {
            os_log("ModelContainer 创建失败，无法打开设置窗口", log: OSLog.default, type: .error)
            return
        }

        openSettingsWindowWithContainer(container)
    }

    private func tryEnsureModelContainer() -> ModelContainer? {
        if let existing = modelContainer {
            return existing
        }
        setupModelContainer()
        if let container = modelContainer {
            windowMover?.configure(modelContext: container.mainContext)
        }
        return modelContainer
    }

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
        setupWindowMoverWorkItem?.cancel()
        setupWindowMoverWorkItem = nil

        permissionCheckTimer?.cancel()
        permissionCheckTimer = nil

        // 显式调用 stopMonitoring，避开 ARC 释放链不确定性
        windowMover?.stopMonitoring()
        windowMover = nil

        removeAllObservers()
        unregisterHotKeys()

        // 立即写一次 pending 的 frame 保存，避免最后一次 resize 调整丢失
        if let window = settingsWindow {
            flushPendingFrameSave(window: window)
        }
    }

    // deinit 兜底：applicationWillTerminate 之外（如 crash）也清理 observer。
    // deinit 是 nonisolated，不能调 @MainActor 方法，故直接内联清理逻辑
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
        if let token = closePanelObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
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
        if let token = closePanelObserverToken {
            NotificationCenter.default.removeObserver(token)
            closePanelObserverToken = nil
        }
        // NSEvent 监听随清理一并移除
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}

// MARK: - NSWindowDelegate
// class 声明已遵循 NSWindowDelegate，extension 重复声明会触发 redundant conformance 错误
extension AppDelegate {
    // 实时写 settingsWindow frame 到 UserDefaults（0.5s 防抖，避免频繁写盘卡 UI）
    func windowDidMove(_ notification: Notification) {
        saveSettingsWindowFrameDebounced(from: notification.object as? NSWindow)
    }

    func windowDidResize(_ notification: Notification) {
        saveSettingsWindowFrameDebounced(from: notification.object as? NSWindow)
    }

    func windowDidResignKey(_ notification: Notification) {
        // 点击本应用其他窗口（如设置窗口）时面板失焦即收起；
        // orderOut 触发的二次 resignKey 由 hideAppPanel 的 isVisible 守卫拦截
        guard let window = notification.object as? NSWindow, window == appPanel else { return }
        hideAppPanel()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // 用户拖拽窗口边缘结束：写回持久化高度（系统已由 contentMin/MaxSize 限制范围）
        guard let window = notification.object as? NSWindow, window == appPanel else { return }
        persistAppPanelHeight(window.frame.height)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // 面板：app 终止等 close 路径保存高度，不走设置窗口 frame 落盘
        if window == appPanel {
            persistAppPanelHeight(window.frame.height)
            return
        }
        // 立即写一次（取消 pending 防抖），确保关闭前 frame 已落盘
        flushPendingFrameSave(window: window)
        // 解除反向引用
        if window == settingsWindow {
            window.delegate = nil
            settingsWindow = nil
        }
    }

    /// 防抖：0.5s 内的多次 move/resize 只触发一次写盘
    private func saveSettingsWindowFrameDebounced(from window: NSWindow?) {
        guard let window = window, window == settingsWindow else { return }
        saveFrameWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.writeSettingsWindowFrame(window: window)
        }
        saveFrameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// 取消 pending 防抖并立即同步写一次
    // 不检查 window == settingsWindow：windowWillClose 已将其置 nil，但 frame 写入
    // 不应依赖此引用（applicationWillTerminate 调用时窗口可能已 close）
    private func flushPendingFrameSave(window: NSWindow) {
        saveFrameWorkItem?.cancel()
        saveFrameWorkItem = nil
        writeSettingsWindowFrame(window: window)
    }

    /// 实际写盘（防抖落地点 / 立即写共用）
    // 仅检查窗口有效性（frame > 0），不依赖 settingsWindow 引用（可能已置 nil）
    private func writeSettingsWindowFrame(window: NSWindow) {
        let frame = window.frame
        guard frame.width > 0 && frame.height > 0 else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.settingsWindowFrameKey)
    }
}
