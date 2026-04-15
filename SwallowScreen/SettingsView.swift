//
//  SettingsView.swift
//  SwallowScreen
//
//  设置窗口视图 - 包含应用基础设置
//

import SwiftUI
import SwiftData
import ServiceManagement

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var appSettings: [AppSettings]
    
    @State private var launchAtLogin: Bool = false
    @State private var enableAutoMove: Bool = true
    @State private var checkInterval: Double = 2.0
    @State private var showHelpTips: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("设置")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
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
        .frame(width: 400, height: 380)
        .onAppear {
            loadSettings()
        }
    }
    
    private func loadSettings() {
        if let settings = appSettings.first {
            launchAtLogin = settings.launchAtLogin
            enableAutoMove = settings.enableAutoMove
            checkInterval = settings.checkInterval
            showHelpTips = settings.showHelpTips
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

#Preview {
    SettingsView()
        .modelContainer(for: [AppSettings.self], inMemory: true)
}
