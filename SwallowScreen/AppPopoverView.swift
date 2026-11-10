//
//  AppPopoverView.swift
//  SwallowScreen
//
//  托盘弹出视图 - 包含搜索框、应用列表和设置工具栏
//

import SwiftUI
import SwiftData
import AppKit
import os.log
// SPM 构建下 UpdateChannel 位于 SwallowScreenCore 模块；Xcode 工程为平面 target 无需 import
#if canImport(SwallowScreenCore)
import SwallowScreenCore
#endif

struct AppPopoverView: View {
    @Environment(\.modelContext) private var modelContext
    // 改用 @EnvironmentObject：由 AppDelegate 注入，跨面板生命周期复用；
    // @StateObject 每次面板重建都会重扫目录和图标缓存
    @EnvironmentObject private var appManager: AppManager
    @EnvironmentObject private var screenManager: ScreenManager

    @Query private var appInfos: [AppInfo]
    @Query private var appSettings: [AppSettings]

    @State private var searchText = ""
    @State private var selectedAppForConfig: SystemApp?

    @State private var showWelcomeTip: Bool = false

    @State private var isCheckingUpdate: Bool = false
    @State private var updateStatus: UpdateChecker.UpdateStatus = .idle
    @State private var latestVersion: String = ""
    @State private var downloadURL: String = ""

    var body: some View {
        ZStack {
            backgroundView

            VStack(spacing: 0) {
                if showWelcomeTip {
                    welcomeTipView
                }
                searchArea

                Divider()

                appListArea

                Divider()

                toolbarArea
            }

            // 自绘更新弹窗（替代 SwiftUI .alert）：
            // 面板是 nonactivatingPanel 不激活应用，系统 sheet 依赖 key window 交互，
            // 弹出后按钮事件无法处理导致遮罩残留；自绘 overlay 直接由按钮置 state 关闭
            if showUpdateAlert {
                updateAlertOverlay
            }
            if showUpToDateAlert {
                upToDateAlertOverlay
            }
        }
        // NSPanel(.titled + .fullSizeContentView) 的隐藏标题栏会注入顶部 safe area inset，
        // 内容默认下移让位形成顶部空白带；忽略它让内容顶到窗口上缘
        .ignoresSafeArea(edges: .top)
        // 宽度固定 360（与 NSPanel contentMin/MaxSize 一致）；
        // 高度由窗口 frame 决定（系统原生拖拽 resize），内容自动填满
        .frame(width: PanelGeometry.panelWidth)
        // esc 关闭面板（替代 NSPopover 内建 esc 行为）；弹窗打开时优先关弹窗
        .onExitCommand {
            if showUpdateAlert { showUpdateAlert = false; return }
            if showUpToDateAlert { showUpToDateAlert = false; return }
            NotificationCenter.default.post(name: .closeAppPanel, object: nil)
        }
        .onAppear {
            // AppManager 跨面板生命周期复用，每次打开时重置搜索状态
            if appManager.searchText != "" {
                appManager.searchText = ""
            }
            setupSettings()
            refreshScreens()
            checkWelcomeTip()
            if appSettings.first?.checkUpdateOnLaunch ?? true {
                autoCheckForUpdate()
            }
        }
    }
    
    @State private var showUpdateAlert: Bool = false
    @State private var showUpToDateAlert: Bool = false
    
    // MARK: - 背景视图
    private var backgroundView: some View {
        VisualEffectView(material: .popover, blendingMode: .behindWindow, state: .active)
            .ignoresSafeArea()
    }
    
    // MARK: - 更新弹窗（自绘 overlay，替代 SwiftUI .alert）
    // 统一弹窗卡片样式：毛玻璃材质 + 圆角，与面板视觉一致
    private var updateAlertOverlay: some View {
        panelAlert(
            title: "发现新版本 v\(latestVersion)",
            message: "是否要下载并安装新版本？",
            confirmTitle: "下载更新",
            cancelTitle: "稍后",
            confirmAction: {
                showUpdateAlert = false
                openDownloadWindow()
            },
            cancelAction: { showUpdateAlert = false }
        )
    }
    
    private var upToDateAlertOverlay: some View {
        panelAlert(
            title: "已是最新版本",
            message: "当前版本已是最新，无需更新。",
            confirmTitle: "确定",
            cancelTitle: nil,
            confirmAction: { showUpToDateAlert = false },
            // cancelTitle 为 nil 不显示取消按钮，但传入 action 让点击遮罩也能关闭
            //（与 updateAlert 行为一致，避免遮罩点了没反应）
            cancelAction: { showUpToDateAlert = false }
        )
    }
    
    /// 面板内弹窗卡片：半透明遮罩 + 居中卡片（标题/消息/操作按钮）
    private func panelAlert(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String?,
        confirmAction: @escaping () -> Void,
        cancelAction: (() -> Void)?
    ) -> some View {
        ZStack {
            // 遮罩层：点击空白处等同于取消（与取消按钮同语义）
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    if let cancelAction { cancelAction() }
                }
            
            VStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    if let cancelTitle, let cancelAction {
                        Button(cancelTitle) { cancelAction() }
                            .buttonStyle(ToolbarButtonStyle())
                    }
                    Button(confirmTitle) { confirmAction() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor)
                        )
                        .foregroundColor(.white)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .padding(24)
        }
    }
    
    // MARK: - 欢迎提示视图
    private var welcomeTipView: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("使用提示")
                    .font(.headline)
                Spacer()
                Button(action: {
                    showWelcomeTip = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Text("搜索并选择应用，然后为其指定显示屏幕。软件启动时会自动恢复到预设屏幕。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
            
            HStack(spacing: 16) {
                Button("不再显示") {
                    showWelcomeTip = false
                    updateSetting { $0.showHelpTips = false }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
                
                Spacer()
                
                Button("知道了") {
                    showWelcomeTip = false
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
    
    private func checkWelcomeTip() {
        if let settings = appSettings.first, settings.showHelpTips {
            showWelcomeTip = true
        }
    }
    
    // MARK: - 搜索区域
    private var searchArea: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("搜索应用...", text: $searchText)
                .textFieldStyle(.plain)
                .onChange(of: searchText) { _, newValue in
                    appManager.searchText = newValue
                }
            
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    appManager.searchText = ""
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        // 圆角浅色背景突出搜索焦点（毛玻璃上用 primary 低透明度，深浅色模式都自然）
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(12)
    }

    // MARK: - 应用列表区域
    private var appListArea: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if appManager.installedApps.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("正在扫描应用...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 24)
                } else if appManager.filteredApps.isEmpty {
                    // 搜索无结果空状态
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("未找到匹配应用")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(appManager.filteredApps) { app in
                        AppRowView(
                            app: app,
                            screens: screenManager.screens,
                            selectedScreen: getSelectedScreen(for: app),
                            isPinToScreen: getIsPinToScreen(for: app),
                            isMenuBarApp: app.isMenuBarApp,
                            onScreenSelected: { screenInfo in
                                configureApp(app: app, screen: screenInfo)
                            },
                            onPinToScreenChanged: { pinned in
                                updatePinToScreen(app: app, pinned: pinned)
                            },
                            onRequestIcon: { completion in
                                appManager.requestIcon(for: app, completion: completion)
                            }
                        )

                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - 工具栏区域
    private var toolbarArea: some View {
        HStack {
            Button(action: {
                openSettingsWindow()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("设置")
                }
            }
            .buttonStyle(ToolbarButtonStyle())
            .foregroundColor(.primary)

            Spacer()

            Button(action: {
                checkForUpdate()
            }) {
                HStack(spacing: 4) {
                    if isCheckingUpdate {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: updateStatus == .available ? "arrow.down.circle.fill" : "arrow.clockwise")
                    }
                    Text(updateButtonText)
                }
            }
            .buttonStyle(ToolbarButtonStyle())
            .foregroundColor(updateStatus == .available ? .green : .primary)
            .disabled(isCheckingUpdate)

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                    Text("退出")
                }
            }
            .buttonStyle(ToolbarButtonStyle())
            .foregroundColor(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    
    // MARK: - 辅助方法
    private func setupSettings() {
        let descriptor = FetchDescriptor<AppSettings>()
        do {
            let results = try modelContext.fetch(descriptor)
            if results.isEmpty {
                let newSettings = AppSettings()
                modelContext.insert(newSettings)
                // 失败时 os_log + 弹 NSAlert；原 try? 静默吞错，首次启动 settings 不持久化也无感知
                do {
                    try modelContext.save()
                } catch {
                    os_log("setupSettings save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
                    AppDelegate.showSaveErrorAlert(error: error)
                }
            }
        } catch {
            os_log("setupSettings fetch 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
        }
    }
    
    private func refreshScreens() {
        screenManager.refreshScreens()
    }
    
    private func getSelectedScreen(for app: SystemApp) -> ScreenInfo? {
        if let appInfo = appInfos.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            // 1. 优先通过序列号匹配（最可靠）
            if let serialNumber = appInfo.targetScreenSerialNumber {
                if let screen = screenManager.screens.first(where: { $0.serialNumber == serialNumber }) {
                    return screen
                }
            }
            // 2. 通过 ID 匹配
            if let screenID = appInfo.targetScreenID,
               let screen = screenManager.screens.first(where: { $0.id == screenID }) {
                return screen
            }
            // 3. 通过 name 匹配——走 screenManager.screen(name:) 统一入口，
            //    内含旧版分辨率后缀兼容逻辑（如 "DELL U2720Q (2560x1440)"）
            if let screenName = appInfo.targetScreenName {
                return screenManager.screen(name: screenName)
            }
        }
        return nil
    }
    
    private func configureApp(app: SystemApp, screen: ScreenInfo?) {
        if let existingInfo = appInfos.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            existingInfo.updateScreen(
                screenID: screen?.id,
                screenName: screen?.name,
                screenSerialNumber: screen?.serialNumber
            )
            // 清空目标屏幕时同步关闭 pinToScreen——无目标屏幕的 pin 是无效状态，
            // 且必须先于下方 isEnabled 逻辑执行，否则 isEnabled 不会正确关闭
            if screen == nil && existingInfo.pinToScreen {
                existingInfo.updatePinToScreen(false)
            }
            // 选屏 ↔ isEnabled 双向同步，与 AppDelegate.setCurrentAppScreen/clearCurrentAppScreen 对齐：
            // 选 nil 屏 = 无目标屏幕 = isEnabled=false，避免定时器空转
            if screen != nil && !existingInfo.isEnabled {
                existingInfo.isEnabled = true
            } else if screen == nil && existingInfo.isEnabled && !existingInfo.pinToScreen {
                existingInfo.isEnabled = false
            }
        } else {
            let newInfo = AppInfo(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                targetScreenID: screen?.id,
                targetScreenName: screen?.name,
                targetScreenSerialNumber: screen?.serialNumber
            )
            // 与 if 分支对齐：无目标屏幕时 isEnabled = false
            if screen == nil {
                newInfo.isEnabled = false
            }
            modelContext.insert(newInfo)
        }

        // 失败时 os_log + 弹 NSAlert；原 try? 静默吞错，屏幕配置修改丢失也无感知
        do {
            try modelContext.save()
            // 选屏后通知 WindowMover 刷新缓存和 pinObserver，与 updatePinToScreen 对齐
            NotificationCenter.default.post(name: .pinToScreenChanged, object: nil)
        } catch {
            os_log("configureApp save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
            AppDelegate.showSaveErrorAlert(error: error)
        }
    }
    
    private func getIsPinToScreen(for app: SystemApp) -> Bool {
        if let appInfo = appInfos.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            return appInfo.pinToScreen
        }
        return false
    }
    
    private func updatePinToScreen(app: SystemApp, pinned: Bool) {
        if let existingInfo = appInfos.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            // 启用 pin 时校验是否已配目标屏——无 targetScreen 的 pin 是静默无效操作
            // （写库成功但 resolveTargetFrame 返回 nil → 静默跳过），此处显式拒绝并告警
            if pinned && existingInfo.targetScreenID == nil
                && existingInfo.targetScreenSerialNumber == nil
                && existingInfo.targetScreenName == nil {
                let error = NSError(
                    domain: "PinToScreen",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "请先为此应用选择屏幕，然后再启用固定屏幕"]
                )
                os_log("updatePinToScreen: bundleID=%{public}@ 尝试启用 pin 但无目标屏",
                       log: OSLog.default, type: .error, app.bundleIdentifier)
                AppDelegate.showSaveErrorAlert(error: error)
                return
            }
            existingInfo.updatePinToScreen(pinned)
            // 关闭 pin 时同步禁用规则——pin 关闭后无持续监控需求，
            // 但若仍有目标屏幕则保留 isEnabled（下次启动仍搬动），仅在无目标屏幕时才禁用
            if !pinned && existingInfo.isEnabled
                && existingInfo.targetScreenID == nil
                && existingInfo.targetScreenSerialNumber == nil
                && existingInfo.targetScreenName == nil {
                existingInfo.isEnabled = false
            }
        } else {
            // 新建时同样校验——无 targetScreen 的新 App 不能直接启用 pin
            if pinned {
                let error = NSError(
                    domain: "PinToScreen",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "请先为此应用选择屏幕，然后再启用固定屏幕"]
                )
                os_log("updatePinToScreen: bundleID=%{public}@ 新建 AppInfo 尝试启用 pin 但无目标屏",
                       log: OSLog.default, type: .error, app.bundleIdentifier)
                AppDelegate.showSaveErrorAlert(error: error)
                return
            }
            let newInfo = AppInfo(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                pinToScreen: pinned
            )
            modelContext.insert(newInfo)
        }

        // 与 setCurrentAppScreen / clearCurrentAppScreen 路径一致——失败时弹 NSAlert
        do {
            try modelContext.save()
        } catch {
            os_log("updatePinToScreen save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
            AppDelegate.showSaveErrorAlert(error: error)
        }

        // 启用或关闭固定屏幕时，立即触发检查
        // 关闭 pinToScreen 时也必须发通知，否则 WindowMover 的 cachedPinnedApps 不会刷新，
        // pinObserver 不会被移除，100ms 定时器仍会把窗口搬回目标屏幕
        NotificationCenter.default.post(name: .pinToScreenChanged, object: nil)
    }
    
    private func updateSetting(_ update: (AppSettings) -> Void) {
        if let settings = appSettings.first {
            update(settings)
            settings.updatedAt = Date()
            // 显式 save——SwiftData view context 自动 save 时机不确定，进程崩溃时设置修改丢失；
            // showHelpTips 修改不致命，try? 可接受
            try? modelContext.save()
        }
    }
    
    private func openSettingsWindow() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }
    

    private var updateButtonText: String {
        // 文案单一来源：UpdateStatus.displayText（与 AboutView 共用，避免两处不一致）
        updateStatus.displayText
    }
    
    // 自动检查更新（启动时调用）
    // AppPopoverView 是 struct，闭包按值捕获，无需 [weak self]
    private func autoCheckForUpdate() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        updateStatus = .checking
        UpdateChecker.shared.check { result in
            isCheckingUpdate = false
            switch result {
            case .success(let info) where info.hasUpdate:
                latestVersion = info.latestVersion
                downloadURL = info.downloadURL
                updateStatus = .available
                showUpdateAlert = true
            case .failure:
                updateStatus = .error
            case .success:
                updateStatus = .upToDate
            }
        }
    }

    // 手动检查更新（按钮调用）；struct 按值捕获，无 retain cycle 风险
    private func checkForUpdate() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        updateStatus = .checking

        UpdateChecker.shared.check { result in
            isCheckingUpdate = false
            switch result {
            case .success(let info):
                latestVersion = info.latestVersion
                if info.hasUpdate {
                    updateStatus = .available
                    downloadURL = info.downloadURL
                    showUpdateAlert = true
                } else {
                    updateStatus = .upToDate
                    showUpToDateAlert = true
                }
            case .failure:
                updateStatus = .error
            }
        }
    }
    
    private func openDownloadWindow() {
        guard let url = URL(string: downloadURL) else { return }
        // 按设置的更新方式解析下载渠道：官网直连 / gh-proxy 加速（脏数据兜底官网）
        let channel = UpdateChannel(rawValue: appSettings.first?.updateChannel ?? "") ?? .github
        let resolved = URL(string: channel.resolveDownloadURL(url.absoluteString)) ?? url
        DownloadWindowController.open(version: latestVersion, downloadURL: resolved)
    }
}

// MARK: - 工具栏按钮样式
/// plain 基础上加 hover 圆角高亮，与列表行 hover 效果一致
private struct ToolbarButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(isHovering ? 0.1 : 0))
            )
            .onHover { isHovering = $0 }
    }
}

// MARK: - 应用行视图
struct AppRowView: View {
    let app: SystemApp
    let screens: [ScreenInfo]
    let selectedScreen: ScreenInfo?
    let isPinToScreen: Bool
    let isMenuBarApp: Bool
    let onScreenSelected: (ScreenInfo?) -> Void
    let onPinToScreenChanged: (Bool) -> Void
    // 图标按需加载入口；AppPopoverView 注入 AppManager.requestIcon 闭包
    let onRequestIcon: ((@escaping @MainActor (NSImage?) -> Void) -> Void)?

    @State private var isHovering = false
    @State private var displayIcon: NSImage? = nil  // 行级图标缓存

    var body: some View {
        HStack(spacing: 8) {
            // 未选屏幕时禁用 pin 按钮——避免开启无 targetScreen 的 pin（静默无效）
            Button(action: {
                onPinToScreenChanged(!isPinToScreen)
            }) {
                Image(systemName: isPinToScreen ? "pin.circle.fill" : "pin.circle")
                    .font(.system(size: 16))
                    .foregroundColor(isPinToScreen ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(selectedScreen == nil && !isPinToScreen)
            .help(selectedScreen == nil && !isPinToScreen
                  ? "请先选择屏幕，然后再启用固定屏幕"
                  : "固定屏幕：开启后该应用只能在此屏幕显示")

            // 图标优先级：displayIcon → app.icon → SF Symbol
            if let icon = displayIcon ?? app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 24, height: 24)
                    .foregroundColor(.accentColor)
            }
            
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
            
            if app.isSystemApp {
                // 系统应用徽标：淡色胶囊文字标签，区分系统应用与第三方应用
                Text("系统")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            
            if isMenuBarApp {
                Image(systemName: "menubar.rectangle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("菜单栏应用：窗口将约束在指定屏幕")
            }
            
            Spacer(minLength: 8)
            
            // 屏幕选择下拉框 - 最大宽度限制为当前窗口的50%
            Menu {
                Button("不指定屏幕") {
                    onScreenSelected(nil)
                }
                
                Divider()
                
                ForEach(screens) { screen in
                    Button {
                        onScreenSelected(screen)
                    } label: {
                        HStack {
                            Text(screen.displayName)
                            Spacer()
                            if selectedScreen?.id == screen.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if let screen = selectedScreen {
                        Text(screen.displayName)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("不指定")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                )
                .frame(maxWidth: 180, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.1) : Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
        // 行首次可见时触发按需图标加载；displayIcon / app.icon 命中则跳过
        .onAppear {
            guard displayIcon == nil, app.icon == nil else { return }
            onRequestIcon? { [self] icon in
                displayIcon = icon
            }
        }
    }
}

// MARK: - 通知名称
extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")

    static let pinToScreenChanged = Notification.Name("pinToScreenChanged")

    // esc 关闭菜单面板（AppPopoverView onExitCommand → AppDelegate 收起面板）
    static let closeAppPanel = Notification.Name("closeAppPanel")
}

#Preview {
    AppPopoverView()
        .modelContainer(for: [AppInfo.self, AppSettings.self], inMemory: true)
        .environmentObject(AppManager())
        .environmentObject(ScreenManager())
}
