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
    
    var body: some View {
        ZStack {
            // 毛玻璃背景
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
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
        .frame(width: 360, height: 400)
        .onAppear {
            setupSettings()
            refreshScreens()
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
                        onScreenSelected: { screenInfo in
                            configureApp(app: app, screen: screenInfo)
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
        HStack(spacing: 16) {
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
            
            Button(action: {
                openHelp()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                    Text("帮助")
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)
            
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
        .padding(12)
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
            print("Error fetching settings: \(error)")
        }
    }
    
    private func refreshScreens() {
        screenManager.refreshScreens()
    }
    
    private func getSelectedScreen(for app: SystemApp) -> ScreenInfo? {
        if let appInfo = appInfos.first(where: { $0.bundleIdentifier == app.bundleIdentifier }),
           let screenID = appInfo.targetScreenID {
            return screenManager.screens.first { $0.id == screenID }
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
    
    private func openSettingsWindow() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }
    
    private func openHelp() {
        if let url = URL(string: "https://github.com/thking/SwallowScreen") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 应用行视图
struct AppRowView: View {
    let app: SystemApp
    let screens: [ScreenInfo]
    let selectedScreen: ScreenInfo?
    let onScreenSelected: (ScreenInfo?) -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        HStack(spacing: 8) {
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
            
            Spacer(minLength: 8)
            
            // 屏幕选择下拉框 - 右对齐
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
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                )
            }
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
}

#Preview {
    AppPopoverView()
        .modelContainer(for: [AppInfo.self, AppSettings.self], inMemory: true)
}
