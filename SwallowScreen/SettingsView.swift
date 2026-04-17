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
    
    @State private var launchAtLogin: Bool = false
    @State private var showHelpTips: Bool = true
    @State private var checkUpdateOnLaunch: Bool = true
    
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
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, newValue in
                                updateSetting { $0.launchAtLogin = newValue }
                                setLaunchAtLogin(enabled: newValue)
                            }
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
                        Toggle("", isOn: $showHelpTips)
                            .labelsHidden()
                            .onChange(of: showHelpTips) { _, newValue in
                                updateSetting { $0.showHelpTips = newValue }
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
                        Toggle("", isOn: $checkUpdateOnLaunch)
                            .labelsHidden()
                            .onChange(of: checkUpdateOnLaunch) { _, newValue in
                                updateSetting { $0.checkUpdateOnLaunch = newValue }
                            }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            loadSettings()
        }
    }
    
    private func loadSettings() {
        if let settings = appSettings.first {
            launchAtLogin = settings.launchAtLogin
            showHelpTips = settings.showHelpTips
            checkUpdateOnLaunch = settings.checkUpdateOnLaunch
        }
    }
    
    private func updateSetting(_ update: (AppSettings) -> Void) {
        if let settings = appSettings.first {
            update(settings)
            settings.updatedAt = Date()
        } else {
            let newSettings = AppSettings()
            update(newSettings)
            modelContext.insert(newSettings)
        }
    }
    
    private func setLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to set launch at login: \(error)")
            }
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
                .onChange(of: setScreenModifiers) { _, _ in saveHotkey(.setScreen) }
                .onChange(of: setScreenKeyCode) { _, _ in saveHotkey(.setScreen) }
                
                // 取消前台应用屏幕设置
                HotkeyCard(
                    title: "取消屏幕设置",
                    subtitle: "取消当前应用的屏幕固定",
                    modifiers: $clearScreenModifiers,
                    keyCode: $clearScreenKeyCode,
                    isRecording: recordingHotkey == .clearScreen,
                    onStartRecording: { recordingHotkey = .clearScreen }
                )
                .onChange(of: clearScreenModifiers) { _, _ in saveHotkey(.clearScreen) }
                .onChange(of: clearScreenKeyCode) { _, _ in saveHotkey(.clearScreen) }
            }
            .padding(20)
        }
        .onAppear {
            loadSettings()
        }
        .onChange(of: recordingHotkey) { _, newValue in
            if newValue != nil {
                startRecording()
            } else {
                stopRecording()
            }
        }
    }
    
    private func startRecording() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.recordingHotkey != nil else { return event }
            
            let keyCode = UInt32(event.keyCode)
            var flags: UInt32 = 0
            
            if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
            if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
            if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
            if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
            
            if keyCode == 0x35 {
                DispatchQueue.main.async {
                    self.recordingHotkey = nil
                }
                return nil
            }
            
            if flags == 0 {
                return nil
            }
            
            DispatchQueue.main.async {
                self.setRecordedHotkey(keyCode: keyCode, flags: flags)
                self.recordingHotkey = nil
            }
            
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
            NotificationCenter.default.post(name: .hotkeysUpdated, object: nil)
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
    @State private var currentVersion: String = ""
    @State private var latestVersion: String = ""
    @State private var isCheckingUpdate: Bool = false
    @State private var updateStatus: UpdateStatus = .idle
    @State private var downloadURL: String = ""
    
    enum UpdateStatus {
        case idle
        case checking
        case available
        case upToDate
        case error
    }
    
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
            checkForUpdate()
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
                        
                        if self.latestVersion == self.currentVersion {
                            self.updateStatus = .upToDate
                        } else {
                            self.updateStatus = .available
                            if let assets = json["assets"] as? [[String: Any]],
                               let firstAsset = assets.first,
                               let browserDownloadURL = firstAsset["browser_download_url"] as? String {
                                self.downloadURL = browserDownloadURL
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
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
        ]
        
        return keyMap[keyCode] ?? "?"
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
