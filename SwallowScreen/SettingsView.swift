//
//  SettingsView.swift
//  SwallowScreen
//
//  设置窗口视图 - 包含应用基础设置
//

import SwiftUI
import SwiftData
import ServiceManagement
import Carbon.HIToolbox
import AppKit

struct SettingsView: View {
    @State private var selectedTab: Int = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
                .tag(0)
            
            HotkeySettingsView()
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }
                .tag(1)
            
            AboutView()
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
                .tag(2)
        }
        .frame(width: 500, height: 400)
        .background(Color.white)
    }
}

// MARK: - 通用设置视图
struct GeneralSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var appSettings: [AppSettings]
    
    @State private var launchAtLogin: Bool = false
    @State private var showHelpTips: Bool = true
    @State private var popoverBackgroundOpacity: Double = 1.0
    
    var body: some View {
        Form {
            Section {
                Toggle("开机启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateSetting { $0.launchAtLogin = newValue }
                        setLaunchAtLogin(enabled: newValue)
                    }
            } header: {
                Text("基础设置")
            }
            
            Section {
                Toggle("显示帮助提示", isOn: $showHelpTips)
                    .onChange(of: showHelpTips) { _, newValue in
                        updateSetting { $0.showHelpTips = newValue }
                    }
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("弹窗背景透明度")
                        Spacer()
                        Text("\(Int(popoverBackgroundOpacity * 100))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $popoverBackgroundOpacity, in: 0.3...1.0, step: 0.1)
                        .onChange(of: popoverBackgroundOpacity) { _, newValue in
                            updateSetting { $0.popoverBackgroundOpacity = newValue }
                        }
                }
                .padding(.vertical, 4)
            } header: {
                Text("界面设置")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            loadSettings()
        }
    }
    
    private func loadSettings() {
        if let settings = appSettings.first {
            launchAtLogin = settings.launchAtLogin
            showHelpTips = settings.showHelpTips
            popoverBackgroundOpacity = settings.popoverBackgroundOpacity
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
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HotkeyRecorderView(
                        title: "设置前台应用屏幕",
                        modifiers: $setScreenModifiers,
                        keyCode: $setScreenKeyCode,
                        isRecording: recordingHotkey == .setScreen,
                        onStartRecording: { recordingHotkey = .setScreen }
                    )
                    .onChange(of: setScreenModifiers) { _, _ in saveHotkey(.setScreen) }
                    .onChange(of: setScreenKeyCode) { _, _ in saveHotkey(.setScreen) }
                    
                    HotkeyRecorderView(
                        title: "取消前台应用屏幕设置",
                        modifiers: $clearScreenModifiers,
                        keyCode: $clearScreenKeyCode,
                        isRecording: recordingHotkey == .clearScreen,
                        onStartRecording: { recordingHotkey = .clearScreen }
                    )
                    .onChange(of: clearScreenModifiers) { _, _ in saveHotkey(.clearScreen) }
                    .onChange(of: clearScreenKeyCode) { _, _ in saveHotkey(.clearScreen) }
                }
                .padding(.vertical, 8)
            } header: {
                Text("快捷键设置")
            } footer: {
                Text("点击快捷键区域录制新快捷键")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
        ScrollView {
            VStack(spacing: 20) {
                // 应用图标和名称
                HStack(spacing: 16) {
                    if let appIcon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 80, height: 80)
                            .cornerRadius(16)
                    } else {
                        Image("AppIcon")
                            .resizable()
                            .frame(width: 80, height: 80)
                            .cornerRadius(16)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SwallowScreen")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        HStack {
                            Text("版本 \(currentVersion)")
                                .foregroundColor(.secondary)
                            if !latestVersion.isEmpty && latestVersion != currentVersion {
                                Text("→ \(latestVersion)")
                                    .foregroundColor(.green)
                                    .fontWeight(.medium)
                            }
                        }
                        .font(.subheadline)
                    }
                    
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top)
                
                Divider()
                    .padding(.horizontal)
                
                // 应用简介
                VStack(alignment: .leading, spacing: 6) {
                    Text("应用简介")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text("一款帮助你管理应用窗口在不同屏幕上显示的工具。支持固定应用到指定屏幕、多屏幕窗口管理、全局快捷键操作。")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                // 开发者信息
                VStack(alignment: .leading, spacing: 6) {
                    Text("开发者")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text("Qithking")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                // GitHub 链接
                Button(action: openGitHub) {
                    HStack {
                        Image(systemName: "link")
                        Text("GitHub 项目地址")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .padding(.horizontal)
                
                // 许可证
                VStack(alignment: .leading, spacing: 6) {
                    Text("开源协议")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text("GNU General Public License v3.0 (GPLv3)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                Spacer(minLength: 20)
                
                // 检查更新按钮
                VStack(spacing: 12) {
                    Button(action: checkForUpdate) {
                        HStack {
                            if isCheckingUpdate {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            Text(updateButtonText)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCheckingUpdate)
                    
                    if updateStatus == .available {
                        Button(action: downloadUpdate) {
                            Label("下载新版本", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .onAppear {
            loadCurrentVersion()
            checkForUpdate()
        }
    }
    
    private var updateButtonText: String {
        switch updateStatus {
        case .idle:
            return "检查更新"
        case .checking:
            return "检查中..."
        case .available:
            return "发现新版本!"
        case .upToDate:
            return "已是最新版本"
        case .error:
            return "检查更新"
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
    
    private func downloadUpdate() {
        if let url = URL(string: downloadURL) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func openGitHub() {
        if let url = URL(string: "https://github.com/Qithking/SwallowScreen") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 快捷键录制视图
struct HotkeyRecorderView: View {
    let title: String
    @Binding var modifiers: Set<HotkeySettingsView.ModifierKey>
    @Binding var keyCode: UInt32
    let isRecording: Bool
    let onStartRecording: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: {
                    onStartRecording()
                }) {
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
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.2))
                    )
                }
                .buttonStyle(.plain)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    private func keyCodeToString(_ keyCode: UInt32) -> String {
        let keyMap: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
            0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
            0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6",
            0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
            0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/",
            0x2D: "N", 0x2E: "M", 0x2F: ".", 0x31: " ", 0x32: "`",
            0x24: "↩", 0x30: "⇥", 0x33: "⌫", 0x35: "⎋",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
        ]
        
        if keyCode >= 0x12 && keyCode <= 0x1D {
            let charValue = UInt8(keyCode - 0x12 + 49)
            return String(UnicodeScalar(charValue))
        }
        
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
