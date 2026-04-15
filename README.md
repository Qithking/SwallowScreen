# SwallowScreen

一款 macOS Menu Bar 应用，帮助你管理应用窗口在不同屏幕上的显示位置。

## 功能特性

- **多屏幕支持**：当电脑连接多个屏幕时，可为每个应用指定首选显示屏幕
- **窗口自动移动**：当应用被拖拽到其他屏幕时，会自动记住位置并可在下次启动时恢复
- **简洁界面**：无主界面，通过菜单栏图标快速访问
- **开机启动**：支持开机自动启动

## 界面说明

### 托盘菜单
点击菜单栏图标展开操作页面，包含以下区域：

1. **搜索区域**：通过关键词过滤应用列表
2. **应用列表**：显示系统已安装应用，每项可选择目标屏幕
3. **工具栏**：设置、帮助和退出按钮

### 设置窗口
点击设置按钮弹出独立窗口，可配置：
- 开机启动
- 自动窗口移动
- 窗口位置检查间隔

## 使用方法

### 编译运行
```bash
# 使用 Xcode 打开项目
open SwallowScreen.xcodeproj

# 或使用命令行编译
xcodebuild -project SwallowScreen.xcodeproj -scheme SwallowScreen -configuration Release build
```

### 首次使用
1. 运行应用后，点击菜单栏的图标
2. 在应用列表中找到需要配置的应用
3. 从下拉菜单中选择目标屏幕
4. 应用将在指定屏幕上显示

### 辅助功能权限
窗口移动功能需要辅助功能权限：
1. 打开「系统设置」>「隐私与安全性」>「辅助功能」
2. 找到 SwallowScreen 并开启权限

## 项目结构

```
SwallowScreen/
├── SwallowScreenApp.swift      # 应用入口
├── AppDelegate.swift            # 托盘图标和菜单处理
├── AppPopoverView.swift         # 托盘弹出主界面
├── SettingsView.swift           # 设置窗口视图
├── AppManager.swift             # 系统应用列表管理
├── ScreenManager.swift          # 屏幕/显示器管理
├── WindowMover.swift            # 窗口移动服务
├── AppInfo.swift                # 应用配置数据模型
├── AppSettings.swift            # 全局设置数据模型
└── Info.plist                   # 应用配置（LSUIElement）
```

## 技术栈

- SwiftUI
- SwiftData
- AppKit (NSStatusItem, NSPopover)
- Accessibility API

## 系统要求

- macOS 13.0+
- 多显示器支持

## License

MIT License
