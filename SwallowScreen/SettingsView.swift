//
//  SettingsView.swift
//  SwallowScreen
//
//  设置窗口视图 - 简洁整齐的现代设计
//

import SwiftUI
import SwiftData
import ServiceManagement
import Carbon.HIToolbox
import AppKit
import os.log
// SPM 构建下 UpdateChannel 位于 SwallowScreenCore 模块；Xcode 工程为平面 target 无需 import
#if canImport(SwallowScreenCore)
import SwallowScreenCore
#endif

private let settingsLog = OSLog(subsystem: "com.swallowscreen.SwallowScreen", category: "Settings")

struct SettingsView: View {
    @State private var selectedTab: Int = 0

    private let tabs: [(icon: String, title: String, tag: Int)] = [
        ("gearshape.fill", "通用", 0),
        ("keyboard.fill", "快捷键", 1),
        ("info.circle.fill", "关于", 2),
    ]

    var body: some View {
        ZStack {
            // 毛玻璃背景铺满整窗（含标题栏背后）——与新版面板 NSPanel 同款 popover 材质，
            // 窗口已在 AppDelegate 设为透明 + fullSizeContentView
            VisualEffectView(material: .popover, blendingMode: .behindWindow, state: .active)
                .ignoresSafeArea()
            // 内容在安全区内（避开标题栏区域），保证侧边栏/内容不与红绿灯、标题重叠
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }
        }
        .frame(width: 620, height: 460)
    }

    // MARK: - 侧边栏导航（macOS 13+ 系统设置风格）
    private var sidebar: some View {
        VStack(spacing: 4) {
            ForEach(tabs, id: \.tag) { tab in
                SidebarItem(icon: tab.icon, title: tab.title, isSelected: selectedTab == tab.tag) {
                    selectedTab = tab.tag
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(width: 160)
    }

    // MARK: - 内容区
    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case 0: GeneralSettingsView()
        case 1: HotkeySettingsView()
        default: AboutView()
        }
    }
}

// MARK: - 侧边栏导航项
private struct SidebarItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundColor(isSelected ? Color.accentColor : .primary)
                Text(title)
                    .foregroundColor(isSelected ? Color.accentColor : .primary)
                    .fontWeight(isSelected ? .medium : .regular)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .selectedContentBackgroundColor).opacity(isHovering ? 0.1 : 0)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 点击后 Button 会成为 firstResponder 显示蓝色聚焦环且不消失；
        // 侧边栏是纯导航不参与键盘焦点链，禁用聚焦避免聚焦框残留
        .focusable(false)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 通用设置视图
struct GeneralSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var appSettings: [AppSettings]

    // 开机启动失败时 UI 显示一行告警
    @State private var launchAtLoginError: String?

    private var settings: AppSettings? { appSettings.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SettingsSectionHeader(title: "常规")
                SettingsRow(
                    icon: "power.circle.fill",
                    iconColor: .blue,
                    title: "开机启动",
                    subtitle: "登录时自动启动应用"
                ) {
                    if let s = settings {
                        @Bindable var bindable = s
                        Toggle("", isOn: $bindable.launchAtLogin)
                            .labelsHidden()
                            .onChange(of: s.launchAtLogin) { _, newValue in
                                markUpdated()
                                setLaunchAtLogin(enabled: newValue)
                            }
                    }
                }
                if let error = launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }

                Divider()
                    .padding(.leading, 44)

                SettingsRow(
                    icon: "questionmark.circle.fill",
                    iconColor: .orange,
                    title: "显示帮助提示",
                    subtitle: "在界面上显示操作提示"
                ) {
                    if let s = settings {
                        @Bindable var bindable = s
                        Toggle("", isOn: $bindable.showHelpTips)
                            .labelsHidden()
                            .onChange(of: s.showHelpTips) { _, _ in markUpdated() }
                    }
                }

                Divider()
                    .padding(.leading, 44)

                // 暂停开关与快捷键共用 WindowMover.setPaused 入口；
                // 快捷键切换时写 AppSettings 触发 @Query 刷新，此处 Toggle 状态自动同步
                SettingsRow(
                    icon: "pause.circle.fill",
                    iconColor: .red,
                    title: "暂停窗口管理",
                    subtitle: "暂停后不再自动搬动固定屏幕窗口"
                ) {
                    if let s = settings {
                        @Bindable var bindable = s
                        Toggle("", isOn: $bindable.isPaused)
                            .labelsHidden()
                            .onChange(of: s.isPaused) { _, newValue in
                                markUpdated()
                                WindowMover.shared?.setPaused(newValue)
                            }
                    }
                }

                SettingsSectionHeader(title: "更新")
                SettingsRow(
                    icon: "network.circle.fill",
                    iconColor: .purple,
                    title: "更新方式",
                    subtitle: "下载更新包使用的渠道"
                ) {
                    if let s = settings {
                        @Bindable var bindable = s
                        // 绑定 String rawValue；脏数据由读取侧 UpdateChannel(rawValue:) ?? .github 兜底
                        Picker("", selection: $bindable.updateChannel) {
                            Text("GitHub 官网").tag(UpdateChannel.github.rawValue)
                            Text("GitHub 加速").tag(UpdateChannel.ghproxy.rawValue)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .onChange(of: s.updateChannel) { _, _ in markUpdated() }
                    }
                }

                Divider()
                    .padding(.leading, 44)

                SettingsRow(
                    icon: "arrow.clockwise.circle.fill",
                    iconColor: .green,
                    title: "启动时检查更新",
                    subtitle: "打开应用时自动检查新版本"
                ) {
                    if let s = settings {
                        @Bindable var bindable = s
                        Toggle("", isOn: $bindable.checkUpdateOnLaunch)
                            .labelsHidden()
                            .onChange(of: s.checkUpdateOnLaunch) { _, _ in markUpdated() }
                    }
                }
            }
            // 外层只保留垂直 padding（水平由 SettingsRow/SettingsSectionHeader 的 20pt 负责），
            // 避免与行内水平 padding 叠加成 40pt 缩进——与 HotkeySettingsView 保持一致
            .padding(.vertical, 4)
        }
        .onAppear {
            ensureSettingsExists()
        }
    }

    private func ensureSettingsExists() {
        if settings == nil {
            let newSettings = AppSettings()
            modelContext.insert(newSettings)
            // 失败时 os_log + 弹 NSAlert；原 try? 静默吞错，首次启动 settings 插入失败也无感知
            do {
                try modelContext.save()
            } catch {
                os_log("ensureSettingsExists save 失败: %{public}@", log: settingsLog, type: .error, error.localizedDescription)
                AppDelegate.showSaveErrorAlert(error: error)
            }
        }
    }

    private func markUpdated() {
        settings?.updatedAt = Date()
        // 显式 save——三个开关 onChange 都走这里，进程崩溃时不至于丢失修改；updatedAt 不致命，try? 可接受
        try? modelContext.save()
    }

    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                os_log("设置开机启动失败: %{public}@", log: settingsLog, type: .error, error.localizedDescription)
                launchAtLoginError = "开机启动设置失败：\(error.localizedDescription)"
            }
        } else {
            // 老系统不支持 SMAppService
            launchAtLoginError = "当前 macOS 版本不支持开机启动设置"
        }
    }
}

// MARK: - 快捷键设置视图
struct HotkeySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var appSettings: [AppSettings]
    
    @State private var setScreenModifiers: Set<ModifierKey> = [.command, .shift]
    @State private var setScreenKeyCode: UInt32 = 0x18
    @State private var clearScreenModifiers: Set<ModifierKey> = [.command, .shift]
    @State private var clearScreenKeyCode: UInt32 = 0x19

    @State private var recordingHotkey: HotkeyType? = nil
    @State private var localMonitor: Any?
    // 录制会话的截止时间；过期后自动退出录制（避免按钮卡在"按下快捷键..."）
    @State private var recordingDeadline: Date = .distantPast
    // 用 DispatchSourceTimer，不被主 RunLoop tracking mode 阻塞
    @State private var recordingTimeoutTimer: DispatchSourceTimer?
    // 加载设置期间的标志，防止 onChange 在 loadSettings 时误触发 saveHotkey
    @State private var isLoadingSettings: Bool = false
    
    enum ModifierKey: String, CaseIterable, Hashable {
        case command = "⌘"
        case shift = "⇧"
        case option = "⌥"
        case control = "⌃"
    }
    
    enum HotkeyType {
        case setScreen
        case clearScreen
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SettingsSectionHeader(title: "屏幕固定快捷键")

                HotkeyRow(
                    title: "设置前台应用屏幕",
                    subtitle: "将当前应用固定到指定屏幕",
                    modifiers: $setScreenModifiers,
                    keyCode: $setScreenKeyCode,
                    isRecording: recordingHotkey == .setScreen,
                    onStartRecording: { recordingHotkey = .setScreen }
                )
                .onChange(of: setScreenModifiers) { _, _ in if !isLoadingSettings { saveHotkey(.setScreen) } }
                .onChange(of: setScreenKeyCode) { _, _ in if !isLoadingSettings { saveHotkey(.setScreen) } }

                Divider()
                    .padding(.leading, 20)

                HotkeyRow(
                    title: "取消屏幕设置",
                    subtitle: "取消当前应用的屏幕固定",
                    modifiers: $clearScreenModifiers,
                    keyCode: $clearScreenKeyCode,
                    isRecording: recordingHotkey == .clearScreen,
                    onStartRecording: { recordingHotkey = .clearScreen }
                )
                .onChange(of: clearScreenModifiers) { _, _ in if !isLoadingSettings { saveHotkey(.clearScreen) } }
                .onChange(of: clearScreenKeyCode) { _, _ in if !isLoadingSettings { saveHotkey(.clearScreen) } }

                SettingsSectionHeader(title: "窗口管理快捷键")

                // 固定键位（暂不支持自定义），与 AppSettings 行内默认值同源
                StaticHotkeyRow(title: "移动窗口到上一屏", subtitle: "将前台应用焦点窗口移到上一屏幕", display: "⌘⇧←")
                Divider()
                    .padding(.leading, 20)

                StaticHotkeyRow(title: "移动窗口到下一屏", subtitle: "将前台应用焦点窗口移到下一屏幕", display: "⌘⇧→")
                Divider()
                    .padding(.leading, 20)

                StaticHotkeyRow(title: "暂停/恢复窗口管理", subtitle: "暂停或恢复自动搬动固定屏幕窗口", display: "⌘⇧P")

                SettingsSectionHeader(title: "提示")
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("点击快捷键区域重新录制；每次升级后需重新开启辅助功能权限")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            loadSettings()
        }
        // view 消失时只调 stopRecording/Timeout，避免重复设 nil 触发 onChange
        .onDisappear {
            stopRecording()
            stopRecordingTimeout()
        }
        .onChange(of: recordingHotkey) { _, newValue in
            if newValue != nil {
                recordingDeadline = Date().addingTimeInterval(8.0)
                startRecording()
                startRecordingTimeout()
            } else {
                stopRecording()
                stopRecordingTimeout()
            }
        }
    }

    private func startRecordingTimeout() {
        recordingTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak timer] in
            guard let _ = timer else { return }
            // 不用 [weak self]——HotkeySettingsView 是 struct，weak 不适用；
            // timer 生命周期由 stopRecordingTimeout / 重新 start 控制
            Task { @MainActor in
                if Date() >= self.recordingDeadline {
                    self.recordingHotkey = nil
                }
            }
        }
        timer.resume()
        recordingTimeoutTimer = timer
    }

    private func stopRecordingTimeout() {
        recordingTimeoutTimer?.cancel()
        recordingTimeoutTimer = nil
    }
    
    private func startRecording() {
        // recordingHotkey == nil 时绝不安装 monitor
        guard recordingHotkey != nil else { return }

        // HotkeySettingsView 是 struct，weak 不适用；
        // localMonitor 在 stopRecording() / startRecording() 入口被替换，旧 monitor 引用自动释放
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = UInt32(event.keyCode)
            var flags: UInt32 = 0

            if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }

            // 录制期间 keyDown 必须吞掉（return nil），防止 Cmd+Shift+1 等被传到前台 App 误触发
            if keyCode == 0x35 {
                // Esc: 取消录制
                self.recordingHotkey = nil
                return nil
            }

            if flags == 0 {
                // 纯功能键无 modifier，吞掉但不更新快捷键
                return nil
            }

            // 拒绝纯修饰键组合（keyCode 本身是修饰键而非普通键）
            let modifierKeyCodes: Set<UInt32> = [
                0x38, 0x3C, // Shift, ShiftR
                0x3B, 0x3E, // Ctrl, CtrlR
                0x37, 0x36, // Cmd, CmdR
                0x3A, 0x3D  // Opt, OptR
            ]
            if modifierKeyCodes.contains(keyCode) {
                return nil
            }

            self.setRecordedHotkey(keyCode: keyCode, flags: flags)
            self.recordingHotkey = nil
            return nil
        }
    }
    
    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
    
    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        if let settings = appSettings.first {
            setScreenKeyCode = UInt32(settings.setScreenKeyCode)
            clearScreenKeyCode = UInt32(settings.clearScreenKeyCode)
            
            setScreenModifiers = modifiersFromCarbon(settings.setScreenModifiers)
            clearScreenModifiers = modifiersFromCarbon(settings.clearScreenModifiers)
        }
    }
    
    private func modifiersFromCarbon(_ flags: UInt32) -> Set<ModifierKey> {
        var mods: Set<ModifierKey> = []
        if flags & UInt32(cmdKey) != 0 { mods.insert(.command) }
        if flags & UInt32(shiftKey) != 0 { mods.insert(.shift) }
        if flags & UInt32(optionKey) != 0 { mods.insert(.option) }
        if flags & UInt32(controlKey) != 0 { mods.insert(.control) }
        return mods
    }
    
    private func modifiersToCarbon(_ mods: Set<ModifierKey>) -> UInt32 {
        var flags: UInt32 = 0
        if mods.contains(.command) { flags |= UInt32(cmdKey) }
        if mods.contains(.shift) { flags |= UInt32(shiftKey) }
        if mods.contains(.option) { flags |= UInt32(optionKey) }
        if mods.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }
    
    private func saveHotkey(_ type: HotkeyType) {
        if let settings = appSettings.first {
            switch type {
            case .setScreen:
                settings.setScreenKeyCode = Int32(setScreenKeyCode)
                settings.setScreenModifiers = modifiersToCarbon(setScreenModifiers)
            case .clearScreen:
                settings.clearScreenKeyCode = Int32(clearScreenKeyCode)
                settings.clearScreenModifiers = modifiersToCarbon(clearScreenModifiers)
            }
            settings.updatedAt = Date()
            // 仅成功时 post 通知——失败时 hotkey 不应被旧值重注册
            do {
                try modelContext.save()
                NotificationCenter.default.post(name: .hotkeysUpdated, object: nil)
            } catch {
                os_log("saveHotkey save 失败: %{public}@", log: settingsLog, type: .error, error.localizedDescription)
                AppDelegate.showSaveErrorAlert(error: error)
            }
        }
    }
    
    private func setRecordedHotkey(keyCode: UInt32, flags: UInt32) {
        switch recordingHotkey {
        case .setScreen:
            setScreenKeyCode = keyCode
            setScreenModifiers = modifiersFromCarbon(flags)
        case .clearScreen:
            clearScreenKeyCode = keyCode
            clearScreenModifiers = modifiersFromCarbon(flags)
        case .none:
            break
        }
    }
}

// MARK: - 关于视图
struct AboutView: View {
    @Query private var appSettings: [AppSettings]
    @State private var currentVersion: String = ""
    @State private var latestVersion: String = ""
    @State private var isCheckingUpdate: Bool = false
    @State private var updateStatus: UpdateChecker.UpdateStatus = .idle
    @State private var downloadURL: String = ""
    @State private var releaseNotes: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 版本信息头部：居中展示应用名与版本号，与新版面板顶部简洁风格一致
            VStack(spacing: 4) {
                Text("SwallowScreen")
                    .font(.headline)
                Text("版本 \(currentVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            if updateStatus == .available, !releaseNotes.isEmpty {
                SettingsSectionHeader(title: "更新内容")
                ScrollView {
                    // Release 正文为 markdown 原文；纯文本展示，多行自动换行
                    Text(releaseNotes)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 140)
            }

            SettingsSectionHeader(title: "支持")

            SettingsLinkRow(
                icon: "envelope",
                iconColor: .accentColor,
                title: "反馈问题",
                action: feedback
            )

            Divider()
                .padding(.leading, 44)

            SettingsLinkRow(
                icon: "link",
                iconColor: .accentColor,
                title: "GitHub 项目",
                action: openGitHub
            )

            Divider()
                .padding(.leading, 44)

            SettingsLinkRow(
                icon: updateStatus == .available ? "arrow.down.circle.fill" : "arrow.clockwise",
                iconColor: updateStatus == .available ? .green : .accentColor,
                title: updateButtonText,
                action: checkForUpdate
            ) {
                if isCheckingUpdate {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            if updateStatus == .available {
                Divider()
                    .padding(.leading, 44)

                SettingsLinkRow(
                    icon: "arrow.down.circle.fill",
                    iconColor: .green,
                    title: "下载 v\(latestVersion)",
                    action: openDownloadWindow
                )
            }

            Spacer()

            Text("© 2026 Qithking. GPLv3.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadCurrentVersion()
            // 与 AppPopoverView.onAppear 一致：由 checkUpdateOnLaunch 控制
            if appSettings.first?.checkUpdateOnLaunch ?? true {
                checkForUpdate()
            }
        }
    }
    
    private var updateButtonText: String {
        // 文案单一来源：UpdateStatus.displayText（与 AppPopoverView 共用，避免两处不一致）
        updateStatus.displayText
    }
    
    private func loadCurrentVersion() {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            currentVersion = version
        } else {
            currentVersion = "1.0.0"
        }
    }
    
    private func checkForUpdate() {
        isCheckingUpdate = true
        updateStatus = .checking

        // AboutView 是 struct，weak 不适用
        UpdateChecker.shared.check { result in
            isCheckingUpdate = false
            switch result {
            case .success(let info):
                latestVersion = info.latestVersion
                downloadURL = info.downloadURL
                releaseNotes = info.releaseNotes
                if info.hasUpdate {
                    updateStatus = .available
                } else {
                    updateStatus = .upToDate
                }
            case .failure:
                updateStatus = .error
            }
        }
    }
    
    private func openDownloadWindow() {
        guard let url = URL(string: downloadURL) else { return }
        DownloadWindowController.open(version: latestVersion, downloadURL: url)
    }
    
    private func openGitHub() {
        if let url = URL(string: "https://github.com/Qithking/SwallowScreen") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func feedback() {
        if let url = URL(string: "https://github.com/Qithking/SwallowScreen/issues") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 链接行按钮
/// 列表式链接行：对齐新版面板列表行（hover 高亮 + Divider 分隔），
/// trailing 可附加额外视图（如检查更新的 ProgressView）
struct SettingsLinkRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let action: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    init(
        icon: String,
        iconColor: Color = .accentColor,
        title: String,
        action: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.action = action
        self.trailing = trailing
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 24)

                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)

                Spacer()

                trailing()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(isHovering ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 分组标题组件
/// 分组小标题：去卡片化后用于区隔不同设置分组，对齐新版面板的紧凑层级
struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

// MARK: - 固定键位说明行（不可录制，仅展示）
struct StaticHotkeyRow: View {
    let title: String
    let subtitle: String
    let display: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(display)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

// MARK: - 设置行组件
struct SettingsRow<ToggleContent: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    @ViewBuilder let toggle: () -> ToggleContent
    
    init(
        icon: String,
        iconColor: Color = .accentColor,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder toggle: @escaping () -> ToggleContent
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.toggle = toggle
    }

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            toggle()
        }
        // 行 hover 高亮与新版面板列表行一致（selectedContentBackgroundColor 淡色）
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(isHovering ? 0.1 : 0))
        )
        .onHover { isHovering = $0 }
    }
}

// MARK: - 快捷键行组件
struct HotkeyRow: View {
    let title: String
    let subtitle: String
    @Binding var modifiers: Set<HotkeySettingsView.ModifierKey>
    @Binding var keyCode: UInt32
    let isRecording: Bool
    let onStartRecording: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onStartRecording) {
                HStack(spacing: 4) {
                    if isRecording {
                        Text("按下快捷键...")
                            .foregroundColor(.red)
                    } else {
                        ForEach(Array(modifiers.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { mod in
                            Text(mod.rawValue)
                        }
                        Text(keyCodeToString(keyCode))
                    }
                }
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                )
            }
            .buttonStyle(.plain)

            if !isRecording {
                Text("点击重新录制")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        // 行 hover 高亮与新版面板列表行一致（selectedContentBackgroundColor 淡色）
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(isHovering ? 0.1 : 0))
        )
        .onHover { isHovering = $0 }
    }

    @State private var isHovering = false
    
    // 键码表用 static let 缓存，避免每次渲染都重建 70+ 条目的字典
    private static let keyCodeNames: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
            0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
            0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6",
            0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
            0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/",
            0x2D: "N", 0x2E: "M", 0x2F: ".", 0x31: "Space", 0x32: "`",
            0x24: "Enter", 0x30: "Tab", 0x33: "Delete", 0x35: "Esc",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            // F13-F19
            0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19",
            // 方向键
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            // 小键盘键（Numpad）
            0x52: "Num0", 0x53: "Num1", 0x54: "Num2", 0x55: "Num3", 0x56: "Num4",
            0x57: "Num5", 0x58: "Num6", 0x59: "Num7", 0x5B: "Num8", 0x5C: "Num9",
            0x43: "Num*", 0x45: "Num+", 0x4B: "Num/", 0x4E: "Num-",
            0x51: "Num=", 0x4C: "NumEnter", 0x41: "Num.",
            // 修饰键 / 编辑键
            0x38: "Shift", 0x3C: "ShiftR",
            0x3B: "Ctrl", 0x3E: "CtrlR",
            0x37: "Cmd", 0x36: "CmdR",
            0x3A: "Opt", 0x3D: "OptR",
            // 键码与 Carbon.HIToolbox.Events.h 对齐
            0x72: "Help", 0x47: "NumClear",
            0x73: "Home", 0x74: "PgDn", 0x75: "End", 0x79: "PgUp",
            0x39: "CapsLock"
    ]

    private func keyCodeToString(_ keyCode: UInt32) -> String {
        Self.keyCodeNames[keyCode] ?? "Key(\(keyCode))"
    }
}

// MARK: - 通知名称
extension Notification.Name {
    static let hotkeysUpdated = Notification.Name("hotkeysUpdated")
}

#Preview {
    SettingsView()
        .modelContainer(for: [AppSettings.self], inMemory: true)
}
