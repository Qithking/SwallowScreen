//
//  RelaunchManager.swift
//  SwallowScreen
//
//  应用自更新与重启管理器 - 处理下载完成后的安装替换和重启流程
//

import Foundation
import AppKit
import os.log
// SPM 构建下 RelaunchScriptFactory 位于 SwallowScreenCore 模块（SPM 自动定义 SWIFT_PACKAGE）；
// Xcode 工程为平面 target 无需 import（与 DownloadWindow.swift 同模式）
#if SWIFT_PACKAGE
import SwallowScreenCore
#endif

@MainActor
final class RelaunchManager {
    static let shared = RelaunchManager()

    private let log = OSLog(subsystem: "com.swallowscreen.SwallowScreen", category: "RelaunchManager")

    private init() {}

    /// 更新文件缺失时的用户提示
    private func showUpdateFileMissingAlert(path: String) {
        let alert = NSAlert()
        alert.messageText = "无法安装更新"
        alert.informativeText = "更新文件不存在或已被清理：\n\(path)\n\n请重新检查更新并下载。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 安装新版本并重启应用
    /// - Parameter downloadURL: 下载文件（.dmg 或 .zip）的本地 URL
    func installAndRelaunch(from downloadURL: URL) {
        // 预检：更新文件必须存在——缺失时弹窗告知，静默退出会让用户困惑
        // （bug-58：曾出现脚本引用已被清理的 DMG、点击后应用无声退出）
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: downloadURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            showUpdateFileMissingAlert(path: downloadURL.path)
            return
        }

        let currentAppURL = Bundle.main.bundleURL
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let fileExtension = downloadURL.pathExtension.lowercased()

        let targetAppURL: URL
        if currentAppURL.path.hasPrefix("/Applications/") {
            targetAppURL = currentAppURL
        } else {
            targetAppURL = URL(fileURLWithPath: "/Applications")
                .appendingPathComponent(currentAppURL.lastPathComponent)
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwallowScreen_update_\(UUID().uuidString).sh")

        // 日志与下载文件同目录，安装失败时便于取证
        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwallowScreenUpdates")
            .appendingPathComponent("relaunch.log")
            .path

        let scriptContent: String
        switch fileExtension {
        case "dmg":
            scriptContent = RelaunchScriptFactory.makeDMGScript(
                pid: currentPID,
                dmgPath: downloadURL.path,
                targetAppPath: targetAppURL.path,
                logPath: logPath
            )
        case "zip":
            scriptContent = RelaunchScriptFactory.makeZipScript(
                pid: currentPID,
                zipPath: downloadURL.path,
                targetAppPath: targetAppURL.path,
                logPath: logPath
            )
        default:
            // 不支持的格式，降级为直接打开文件
            NSWorkspace.shared.open(downloadURL)
            return
        }

        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            os_log("写入更新脚本失败: %{public}@", log: log, type: .error, error.localizedDescription)
            NSWorkspace.shared.open(downloadURL)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        do {
            try process.run()
        } catch {
            os_log("执行更新脚本失败: %{public}@", log: log, type: .error, error.localizedDescription)
            NSWorkspace.shared.open(downloadURL)
            return
        }

        // 退出当前应用，脚本会在进程退出后完成安装和重启
        NSApplication.shared.terminate(nil)
    }
}

