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
    @Environment(\.modelContext) private var modelContext
    @Query private var appSettings: [AppSettings]
    
    @State private var launchAtLogin: Bool = false
    @State private var enableAutoMove: Bool = true
    @State private var checkInterval: Double = 2.0
    @State private var showHelpTips: Bool = true
    
    // 快捷键相关状态
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
        ZStack {
            // 毛玻璃背景
            VisualEffectView(material: .windowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 设置内容
                Form {
                    Section {
                        Toggle("开机启动", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, newValue in
                                updateSetting { $0.launchAtLogin = newValue }
                                setLaunchAtLogin(enabled: newValue)
                            }
                        
                        Toggle("启用自动窗口移动", isOn: $enableAutoMove)
                            .onChange(of: enableAutoMove) { _, newValue in
                                updateSetting { $0.enableAutoMove = newValue }
                            }
                        
                        HStack {
                            Text("窗口位置检查间隔")
                            Spacer()
                            Slider(value: $checkInterval, in: 1...10, step: 0.5)
                                .frame(width: 120)
                            Text("\(checkInterval, specifier: "%.1f")秒")
                                .frame(width: 40)
                                .onChange(of: checkInterval) { _, newValue in
                                    updateSetting { $0.checkInterval = newValue }
                                }
                        }
                    } header: {
                        Text("基础设置")
                    }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            // 快捷键 1: 设置屏幕
                            HotkeyRecorderView(
                                title: "设置前台应用屏幕",
                                modifiers: $setScreenModifiers,
                                keyCode: $setScreenKeyCode,
                                isRecording: recordingHotkey == .setScreen,
                                onStartRecording: { recordingHotkey = .setScreen }
                            )
                            .onChange(of: setScreenModifiers) { _, _ in saveHotkey(.setScreen) }
                            .onChange(of: setScreenKeyCode) { _, _ in saveHotkey(.setScreen) }
                            
                            // 快捷键 2: 清除屏幕
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
                        Text("快捷键")
                    } footer: {
                        Text("点击快捷键区域录制新快捷键")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Section {
                        Toggle("显示帮助提示", isOn: $showHelpTips)
                            .onChange(of: showHelpTips) { _, newValue in
                                updateSetting { $0.showHelpTips = newValue }
                            }
                    } header: {
                        Text("界面设置")
                    }
                    
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("关于 SwallowScreen")
                                .font(.headline)
                            Text("版本 1.0.0")
                                .foregroundColor(.secondary)
                            Text("一款帮助你管理应用窗口在不同屏幕上显示的工具。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    } header: {
                        Text("关于")
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 400, height: 480)
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
            
            // ESC 取消录制
            if keyCode == 0x35 {
                DispatchQueue.main.async {
                    self.recordingHotkey = nil
                }
                return nil
            }
            
            // 必须有修饰键
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
            launchAtLogin = settings.launchAtLogin
            enableAutoMove = settings.enableAutoMove
            checkInterval = settings.checkInterval
            showHelpTips = settings.showHelpTips
            
            // 加载快捷键设置
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
            
            // 通知 AppDelegate 重新注册快捷键
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

// MARK: - 快捷键录制视图
struct HotkeyRecorderView: View {
    let title: String
    @Binding var modifiers: Set<SettingsView.ModifierKey>
    @Binding var keyCode: UInt32
    let isRecording: Bool
    let onStartRecording: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // 快捷键显示 - 可点击
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
        
        // 数字键 1-0
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
    static let recordingHotkey = Notification.Name("recordingHotkey")
}

#Preview {
    SettingsView()
        .modelContainer(for: [AppSettings.self], inMemory: true)
}
