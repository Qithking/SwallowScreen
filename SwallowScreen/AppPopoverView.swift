//
//  AppPopoverView.swift
//  SwallowScreen
//
//  托盘弹出视图 - 包含搜索框、应用列表和设置工具栏
//

import SwiftUI
import SwiftData
import AppKit

struct AppPopoverView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var appManager = AppManager()
    @StateObject private var screenManager = ScreenManager()
    
    @Query private var appInfos: [AppInfo]
    @Query private var appSettings: [AppSettings]
    
    @State private var searchText = ""
    @State private var selectedAppForConfig: SystemApp?
    
    @State private var settings: AppSettings?
    @State private var showWelcomeTip: Bool = false
    
    // 检查更新相关状态
    @State private var isCheckingUpdate: Bool = false
    @State private var updateStatus: UpdateStatus = .idle
    @State private var latestVersion: String = ""
    @State private var downloadURL: String = ""
    
    enum UpdateStatus {
        case idle
        case checking
        case available
        case upToDate
        case error
    }
    
    var body: some View {
        ZStack {
            // 毛玻璃背景 - 直接从 appSettings 读取透明度
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .opacity(appSettings.first?.popoverBackgroundOpacity ?? 1.0)
                .ignoresSafeArea()
            
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
            // 自动检查更新
            autoCheckForUpdate()
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
        if let settings = settings, settings.showHelpTips {
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
            }
            settings = results.first
        } catch {
            // 静默处理
        }
    }
    
    private func refreshScreens() {
        screenManager.refreshScreens()
    }
    
    private func getSelectedScreen(for app: SystemApp) -> ScreenInfo? {
        if let appInfo = appInfos.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            // 优先通过 ID 匹配
            if let screenID = appInfo.targetScreenID,
               let screen = screenManager.screens.first(where: { $0.id == screenID }) {
                return screen
            }
            // ID 匹配失败，尝试通过名称匹配（解决重启后屏幕 ID 变化问题）
            if let screenName = appInfo.targetScreenName {
                return screenManager.screens.first { screen in
                    screen.displayName == screenName || 
                    screen.name == screenName ||
                    screen.displayName.contains(screenName.components(separatedBy: " ").first ?? "")
                }
            }
        }
        return nil
    }
    
    private func configureApp(app: SystemApp, screen: ScreenInfo?) {
        if let existingInfo = appInfos.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            existingInfo.updateScreen(screenID: screen?.id, screenName: screen?.displayName)
        } else {
            let newInfo = AppInfo(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                iconData: appManager.getIconData(for: app),
                targetScreenID: screen?.id,
                targetScreenName: screen?.displayName
            )
            modelContext.insert(newInfo)
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
            existingInfo.updatePinToScreen(pinned)
        } else {
            let newInfo = AppInfo(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                iconData: appManager.getIconData(for: app),
                pinToScreen: pinned
            )
            modelContext.insert(newInfo)
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
    
    // 自动检查更新（启动时调用）
    private func autoCheckForUpdate() {
        guard let url = URL(string: "https://api.github.com/repos/Qithking/SwallowScreen/releases/latest") else {
            return
        }
        
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        
        URLSession.shared.dataTask(with: request) { [self] data, _, error in
            guard let data = data, error == nil else { return }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                let newVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                
                if newVersion != currentVersion {
                    DispatchQueue.main.async {
                        self.latestVersion = newVersion
                        if let assets = json["assets"] as? [[String: Any]],
                           let firstAsset = assets.first,
                           let downloadUrl = firstAsset["browser_download_url"] as? String {
                            self.downloadURL = downloadUrl
                            self.showUpdateAlert = true
                        }
                    }
                }
            }
        }.resume()
    }
    
    // 手动检查更新（按钮调用）
    private func checkForUpdate() {
        isCheckingUpdate = true
        updateStatus = .checking
        
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        
        guard let url = URL(string: "https://api.github.com/repos/Qithking/SwallowScreen/releases/latest") else {
            updateStatus = .error
            isCheckingUpdate = false
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        
        URLSession.shared.dataTask(with: request) { [self] data, response, error in
            DispatchQueue.main.async {
                self.isCheckingUpdate = false
                
                guard let data = data, error == nil else {
                    self.updateStatus = .error
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tagName = json["tag_name"] as? String {
                        self.latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                        
                        if self.latestVersion == currentVersion {
                            self.updateStatus = .upToDate
                            self.showUpToDateAlert = true
                        } else {
                            self.updateStatus = .available
                            if let assets = json["assets"] as? [[String: Any]],
                               let firstAsset = assets.first,
                               let browserDownloadURL = firstAsset["browser_download_url"] as? String {
                                self.downloadURL = browserDownloadURL
                                self.showUpdateAlert = true
                            }
                        }
                    } else {
                        self.updateStatus = .error
                    }
                } catch {
                    self.updateStatus = .error
                }
            }
        }.resume()
    }
    
    private func openDownloadWindow() {
        guard let url = URL(string: downloadURL) else { return }
        let controller = DownloadWindowController(version: latestVersion, downloadURL: url)
        controller.showWindow()
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
            Button(action: {
                onPinToScreenChanged(!isPinToScreen)
            }) {
                Image(systemName: isPinToScreen ? "pin.circle.fill" : "pin.circle")
                    .font(.system(size: 16))
                    .foregroundColor(isPinToScreen ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("固定屏幕：开启后该应用只能在此屏幕显示")
            
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
            
            // 屏幕选择下拉框
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
                            if screen.isMain {
                                Text("(主屏幕)")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedScreen?.id == screen.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedScreen?.displayName ?? "不指定")
                        .font(.caption)
                        .foregroundColor(selectedScreen != nil ? .primary : .secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
