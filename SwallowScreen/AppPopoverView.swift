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

struct AppPopoverView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var appManager = AppManager()
    @StateObject private var screenManager = ScreenManager()
    
    @Query private var appInfos: [AppInfo]
    @Query private var appSettings: [AppSettings]
    
    @State private var searchText = ""
    @State private var selectedAppForConfig: SystemApp?

    // R-155: 删除 @State settings 改用 appSettings.first——避免与 @Query appSettings 双数据源不一致
    @State private var showWelcomeTip: Bool = false
    
    // 检查更新相关状态
    @State private var isCheckingUpdate: Bool = false
    // RT106: UpdateStatus 抽到 UpdateChecker 统一引用
    @State private var updateStatus: UpdateChecker.UpdateStatus = .idle
    @State private var latestVersion: String = ""
    @State private var downloadURL: String = ""
    
    var body: some View {
        ZStack {
            // 毛玻璃背景
            backgroundView
            
            VStack(spacing: 0) {
                // 首次使用提示
                if showWelcomeTip {
                    welcomeTipView
                }
                // 第一部分：搜索区域
                searchArea
                
                Divider()
                
                // 第二部分：应用列表区域
                appListArea
                
                Divider()
                
                // 第三部分：系统设置工具栏
                toolbarArea
            }
        }
        .frame(width: 360, height: 500)
        .onAppear {
            setupSettings()
            refreshScreens()
            checkWelcomeTip()
            // 根据设置决定是否检查更新
            if appSettings.first?.checkUpdateOnLaunch ?? true {
                autoCheckForUpdate()
            }
        }
        .alert("发现新版本 v\(latestVersion)", isPresented: $showUpdateAlert) {
            Button("下载更新") {
                openDownloadWindow()
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("是否要下载并安装新版本？")
        }
        .alert("已是最新版本", isPresented: $showUpToDateAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("当前版本已是最新，无需更新。")
        }
    }
    
    @State private var showUpdateAlert: Bool = false
    @State private var showUpToDateAlert: Bool = false
    
    // MARK: - 背景视图
    private var backgroundView: some View {
        VisualEffectView(material: .popover, blendingMode: .behindWindow, state: .active)
            .ignoresSafeArea()
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
        // R-155: 改用 appSettings.first（@Query 自动反映 SwiftData 变化）——不再依赖 setupSettings 设的 @State
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
        .padding(12)
    }
    
    // MARK: - 应用列表区域
    private var appListArea: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // RT50: 扫描中显示 loading 占位
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
            // 左侧：设置按钮
            Button(action: {
                openSettingsWindow()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("设置")
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)
            
            Spacer()
            
            // 右侧：检查更新和退出按钮
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
            .buttonStyle(.plain)
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
            .buttonStyle(.plain)
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
                // R-191: 走 R-157 路径——失败时 os_log + 弹 NSAlert（与 updatePinToScreen 路径一致）
                //        原 try? modelContext.save() 静默吞错，首次启动 settings 不持久化也无感知
                do {
                    try modelContext.save()
                } catch {
                    os_log("setupSettings save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
                    AppDelegate.showSaveErrorAlert(error: error)
                }
            }
            // R-155: 不再写 @State settings——appSettings.first 始终反映 @Query 自动结果
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
            // 3. 通过 name 匹配——走 screenManager.screen(name:) 统一入口
            //        R-228: screen(name:) 内含旧版分辨率后缀兼容逻辑（如 "DELL U2720Q (2560x1440)"），
            //        此处之前用 $0.name == screenName 精确匹配，旧版 targetScreenName 会匹配失败
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
            // R-226: 选屏 ↔ isEnabled 双向同步——与 AppDelegate.setCurrentAppScreen/clearCurrentAppScreen 对齐
            //        选 nil 屏（"不指定"）= 无目标屏幕 = isEnabled=false，避免定时器空转
            //        选非 nil 屏 = 有目标屏幕 = isEnabled=true，恢复屏幕规则
            if screen != nil && !existingInfo.isEnabled {
                existingInfo.isEnabled = true
            } else if screen == nil && existingInfo.isEnabled && !existingInfo.pinToScreen {
                existingInfo.isEnabled = false
            }
        } else {
            let newInfo = AppInfo(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                iconData: appManager.getIconData(for: app),
                targetScreenID: screen?.id,
                targetScreenName: screen?.name,
                targetScreenSerialNumber: screen?.serialNumber
            )
            modelContext.insert(newInfo)
        }

        // R-192: 走 R-157 路径——失败时 os_log + 弹 NSAlert（与 updatePinToScreen 路径一致）
        //        原 try? modelContext.save() 静默吞错，屏幕配置修改丢失也无感知
        do {
            try modelContext.save()
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
            // R-217: 启用 pin 时校验是否已配目标屏——无 targetScreen 的 pin 是 silent no-op
            //        写库成功但 checkAndEnforcePinnedWindows 的 resolveTargetFrame 返回 nil → 静默跳过
            //        此处显式拒绝，给用户告警
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
            // R-226: 关闭 pin 时同步禁用规则——pin 关闭后无持续监控需求，
            //        但若仍有目标屏幕则保留 isEnabled（下次启动仍搬动），
            //        仅在无目标屏幕时才禁用
            if !pinned && existingInfo.isEnabled
                && existingInfo.targetScreenID == nil
                && existingInfo.targetScreenSerialNumber == nil
                && existingInfo.targetScreenName == nil {
                existingInfo.isEnabled = false
            }
        } else {
            // R-217: 新建时同样校验——无 targetScreen 的新 App 不能直接启用 pin
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
                iconData: appManager.getIconData(for: app),
                pinToScreen: pinned
            )
            modelContext.insert(newInfo)
        }

        // R-157: 与 setCurrentAppScreen / clearCurrentAppScreen 路径一致——失败时弹 NSAlert
        do {
            try modelContext.save()
        } catch {
            os_log("updatePinToScreen save 失败: %{public}@", log: OSLog.default, type: .error, error.localizedDescription)
            AppDelegate.showSaveErrorAlert(error: error)
        }

        // 启用固定屏幕时，立即触发检查
        if pinned {
            NotificationCenter.default.post(name: .pinToScreenChanged, object: nil)
        }
    }
    
    private func updateSetting(_ update: (AppSettings) -> Void) {
        if let settings = appSettings.first {
            update(settings)
            settings.updatedAt = Date()
            // R-189: 显式 save——SwiftData view context 自动 save 时机不确定，
            //        进程崩溃时 `showHelpTips = false` 等设置修改丢失
            //        （welcomeTipView "不再显示" 按钮调此闭包）
            //        showHelpTips 修改不致命，try? 可接受
            try? modelContext.save()
        }
    }
    
    private func openSettingsWindow() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }
    

    private var updateButtonText: String {
        switch updateStatus {
        case .idle, .error:
            return "检查更新"
        case .checking:
            return "检查中..."
        case .available:
            return "发现新版本"
        case .upToDate:
            return "已是最新"
        }
    }
    
    // RT32: 自动检查更新（启动时调用）—— checkUpdateOnLaunch 判断收敛到 onAppear 入口
    // R-188: 入口 isCheckingUpdate = true + 回调内 false——与 checkForUpdate 行为一致，
    //        启动期检查更新时按钮 ProgressView 正常显示
    // R-211: 删除闭包 [weak self]——AppPopoverView 是 struct，weak 不适用；
    //        struct 按值捕获，无 retain cycle 风险
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

    // 手动检查更新（按钮调用）
    // R-211: 删除 [weak self]——AppPopoverView 是 struct，weak 不适用
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
        // RT70: 抽到 DownloadWindowController.open 静态方法
        DownloadWindowController.open(version: latestVersion, downloadURL: url)
    }
}

// MARK: - 应用行视图
struct AppRowView: View {
    let app: SystemApp
    let screens: [ScreenInfo]
    let selectedScreen: ScreenInfo?
    let isPinToScreen: Bool
    let isMenuBarApp: Bool  // 是否是菜单栏应用
    let onScreenSelected: (ScreenInfo?) -> Void
    let onPinToScreenChanged: (Bool) -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 8) {
            // 固定屏幕图标
            // R-217: 未选屏幕时禁用 pin 按钮——避免用户开启无 targetScreen 的 pin（silent no-op）
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
            
            // 应用图标
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 24, height: 24)
                    .foregroundColor(.accentColor)
            }
            
            // 应用名称
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
            
            // 菜单栏应用标记
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
                .frame(maxWidth: 180, alignment: .trailing) // 360px窗口的50%
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.1) : Color.clear)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - 通知名称
extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")

    static let pinToScreenChanged = Notification.Name("pinToScreenChanged")
}

#Preview {
    AppPopoverView()
        .modelContainer(for: [AppInfo.self, AppSettings.self], inMemory: true)
}
