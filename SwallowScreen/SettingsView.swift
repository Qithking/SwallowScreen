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

private let settingsLog = OSLog(subsystem: "com.swallowscreen.SwallowScreen", category: "Settings")

struct SettingsView: View {
    @State private var selectedTab: Int = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // 应用图标
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            } else {
                Image("AppIcon")
                    .resizable()
                    .frame(width: 72, height: 72)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }            
            
            TabView(selection: $selectedTab) {
                GeneralSettingsView()
                    .tabItem {
                        Label("通用", systemImage: "gearshape.fill")
                    }
                    .tag(0)
                
                HotkeySettingsView()
                    .tabItem {
                        Label("快捷键", systemImage: "keyboard.fill")
                    }
                    .tag(1)
                
                AboutView()
                    .tabItem {
                        Label("关于", systemImage: "info.circle.fill")
                    }
                    .tag(2)
            }
        }
        .frame(width: 480, height: 450)
    }
}

// MARK: - 通用设置视图
struct GeneralSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var appSettings: [AppSettings]

    // RT40: 开机启动失败时 UI 显示一行告警
    @State private var launchAtLoginError: String?

    // T22: 不再使用本地 @State 镜像，直接从 @Query 派生 Binding
    private var settings: AppSettings? { appSettings.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 基础设置卡片
                SettingsCard(title: "基础设置") {
                    SettingsRow(
                        icon: "power.circle.fill",
                        iconColor: .blue,
                        title: "开机启动",
                        subtitle: "登录时自动启动应用"
                    ) {
                        // T22: Binding 直接绑定到 SwiftData 模型
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
                    // RT40: 失败时显示告警文本
                    if let error = launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                }

                // 界面设置卡片
                SettingsCard(title: "界面设置") {
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
                        .padding(.vertical, 8)

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
            }
            .padding(20)
        }
        .onAppear {
            ensureSettingsExists()
        }
    }

    private func ensureSettingsExists() {
        if settings == nil {
            let newSettings = AppSettings()
            modelContext.insert(newSettings)
            // R-193: 走 R-157 路径——失败时 os_log + 弹 NSAlert（与 updatePinToScreen 路径一致）
            //        原 try? modelContext.save() 静默吞错，首次启动 settings 插入失败也无感知
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
        // R-196: 显式 save——launchAtLogin / showHelpTips / checkUpdateOnLaunch 三个开关 onChange 都走这里
        //        进程崩溃时这些修改 + updatedAt 都丢失
        //        updatedAt 修改不致命，try? 可接受
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
                // RT40: 成功时清空错误
                launchAtLoginError = nil
            } catch {
                // RT29: 统一改 os_log
                os_log("设置开机启动失败: %{public}@", log: settingsLog, type: .error, error.localizedDescription)
                // RT40: 失败时暴露给 UI
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
    // T16: 录制会话的截止时间；过期后自动退出录制（避免按钮卡在"按下快捷键..."）
    @State private var recordingDeadline: Date = .distantPast
    // RT71: 改 DispatchSourceTimer，与 RT59/RT64 风格一致；不被主 RunLoop tracking mode 阻塞
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
            VStack(spacing: 16) {
                // 快捷键说明
                HStack {
                    Image(systemName: "keyboard")
                        .foregroundColor(.secondary)
                    Text("点击快捷键区域重新录制（注意：每次升级都需要关闭服务权限再重新开启）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                // 设置前台应用屏幕
                HotkeyCard(
                    title: "设置前台应用屏幕",
                    subtitle: "将当前应用固定到指定屏幕",
                    modifiers: $setScreenModifiers,
                    keyCode: $setScreenKeyCode,
                    isRecording: recordingHotkey == .setScreen,
                    onStartRecording: { recordingHotkey = .setScreen }
                )
                .onChange(of: setScreenModifiers) { _, _ in if !isLoadingSettings { saveHotkey(.setScreen) } }
                .onChange(of: setScreenKeyCode) { _, _ in if !isLoadingSettings { saveHotkey(.setScreen) } }
                
                // 取消前台应用屏幕设置
                HotkeyCard(
                    title: "取消屏幕设置",
                    subtitle: "取消当前应用的屏幕固定",
                    modifiers: $clearScreenModifiers,
                    keyCode: $clearScreenKeyCode,
                    isRecording: recordingHotkey == .clearScreen,
                    onStartRecording: { recordingHotkey = .clearScreen }
                )
                .onChange(of: clearScreenModifiers) { _, _ in if !isLoadingSettings { saveHotkey(.clearScreen) } }
                .onChange(of: clearScreenKeyCode) { _, _ in if !isLoadingSettings { saveHotkey(.clearScreen) } }
            }
            .padding(20)
        }
        .onAppear {
            loadSettings()
        }
        // RT51: view 消失时只调 stopRecording/Timeout，避免重复设 nil 触发 onChange
        .onDisappear {
            stopRecording()
            stopRecordingTimeout()
        }
        .onChange(of: recordingHotkey) { _, newValue in
            if newValue != nil {
                // T16: 进入录制时设置 8s 截止时间
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
        // RT71: 改用 DispatchSourceTimer，与 RT59/RT64 风格一致
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak timer] in
            guard let _ = timer else { return }
            // R-211: 删除 [weak self]——HotkeySettingsView 是 struct，weak 不适用
            //        timer 自身的生命周期由 stopRecordingTimeout / 重新 start 控制
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
        // RT107: 入口守门——recordingHotkey == nil 时绝不安装 monitor，避免 race window
        guard recordingHotkey != nil else { return }

        // RT26: [weak self] 避免 retain cycle
        // R-211: 删除 [weak self]——HotkeySettingsView 是 struct，weak 不适用
        //        localMonitor 在 stopRecording() / startRecording() 入口被替换，旧 monitor 引用自动释放
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = UInt32(event.keyCode)
            var flags: UInt32 = 0

            if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }

            // RT107: 录制期间 keyDown 必须吞掉（return nil），
            //       防止 Cmd+Shift+1 等被传到前台 App 误触发
            //       monitor 安装时已 guard recordingHotkey != nil，所以这里不需要再判断
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
                // 吞掉但不更新快捷键
                return nil
            }

            // 正常录制：更新快捷键并退出
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
            // R-198: 仅成功时 post 通知——失败时 hotkey 不应被旧值重注册
            //        R-194 已加 do/try/catch，本轮把 NotificationCenter.post 移到成功路径内
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
    // RT106: UpdateStatus 抽到 UpdateChecker 统一引用
    @State private var updateStatus: UpdateChecker.UpdateStatus = .idle
    @State private var downloadURL: String = ""

    var body: some View {
        VStack(spacing: 16) {            
            
            // 应用名称和版本
            VStack(spacing: 4) {
                Text("SwallowScreen")
                    .font(.headline)
                
                Text("版本 \(currentVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // 按钮
            VStack(spacing: 10) {
                LinkButton(title: "反馈问题", icon: "envelope", action: feedback)
                LinkButton(title: "GitHub 项目", icon: "link", action: openGitHub)
                
                Button(action: checkForUpdate) {
                    HStack(spacing: 6) {
                        if isCheckingUpdate {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: updateStatus == .available ? "arrow.down.circle.fill" : "arrow.clockwise")
                        }
                        Text(updateButtonText)
                    }
                    .frame(maxWidth: 200)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(6)
                .disabled(isCheckingUpdate)
                
                if updateStatus == .available {
                    Button(action: openDownloadWindow) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("下载 v\(latestVersion)")
                        }
                        .frame(maxWidth: 200)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 16)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
            }
            
            // 版权
            Text("© 2026 Qithking. GPLv3.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .padding(.vertical, 16)
        .onAppear {
            loadCurrentVersion()
            // RT44: 与 AppPopoverView.onAppear 守门一致：受 checkUpdateOnLaunch 控制
            if appSettings.first?.checkUpdateOnLaunch ?? true {
                checkForUpdate()
            }
        }
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
            return "已是最新版本"
        }
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

        // R-211: 删除 [weak self]——AboutView 是 struct，weak 不适用
        UpdateChecker.shared.check { result in
            isCheckingUpdate = false
            switch result {
            case .success(let info):
                latestVersion = info.latestVersion
                if info.hasUpdate {
                    updateStatus = .available
                    downloadURL = info.downloadURL
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
        // RT70: 抽到 DownloadWindowController.open 静态方法
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

// MARK: - 链接按钮
struct LinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .frame(maxWidth: 200)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - 设置卡片组件
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
    }
}

// MARK: - 快捷键卡片组件
struct HotkeyCard: View {
    let title: String
    let subtitle: String
    @Binding var modifiers: Set<HotkeySettingsView.ModifierKey>
    @Binding var keyCode: UInt32
    let isRecording: Bool
    let onStartRecording: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack {
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
                
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
    
    private func keyCodeToString(_ keyCode: UInt32) -> String {
        let keyMap: [UInt32: String] = [
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
            // T20: 补充 F13-F19
            0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19",
            // T20: 方向键
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            // T20: 小键盘键（Numpad）
            0x52: "Num0", 0x53: "Num1", 0x54: "Num2", 0x55: "Num3", 0x56: "Num4",
            0x57: "Num5", 0x58: "Num6", 0x59: "Num7", 0x5B: "Num8", 0x5C: "Num9",
            0x43: "Num*", 0x45: "Num+", 0x4B: "Num/", 0x4E: "Num-",
            0x51: "Num=", 0x4C: "NumEnter", 0x41: "Num.",
            // T20: 修饰键 / 编辑键
            0x38: "Shift", 0x3C: "ShiftR",
            0x3B: "Ctrl", 0x3E: "CtrlR",
            0x37: "Cmd", 0x36: "CmdR",
            0x3A: "Opt", 0x3D: "OptR",
            // RT27: 修正键码映射（与 Carbon.HIToolbox.Events.h 对齐）
            0x72: "Help", 0x47: "NumClear",
            0x73: "Home", 0x74: "PgDn", 0x75: "End", 0x79: "PgUp",
            0x39: "CapsLock"
        ]

        return keyMap[keyCode] ?? "Key(\(keyCode))"
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
