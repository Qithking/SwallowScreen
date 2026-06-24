//
//  RelaunchManager.swift
//  SwallowScreen
//
//  应用自更新与重启管理器 - 处理下载完成后的安装替换和重启流程
//

import Foundation
import AppKit
import os.log

@MainActor
final class RelaunchManager {
    static let shared = RelaunchManager()

    private let log = OSLog(subsystem: "com.swallowscreen.SwallowScreen", category: "RelaunchManager")

    private init() {}

    /// 安装新版本并重启应用
    /// - Parameter downloadURL: 下载文件（.dmg 或 .zip）的本地 URL
    func installAndRelaunch(from downloadURL: URL) {
        let currentAppURL = Bundle.main.bundleURL
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let fileExtension = downloadURL.pathExtension.lowercased()

        // 确定目标安装路径：当前在 /Applications 则原地替换，否则安装到 /Applications
        let targetAppURL: URL
        if currentAppURL.path.hasPrefix("/Applications/") {
            targetAppURL = currentAppURL
        } else {
            targetAppURL = URL(fileURLWithPath: "/Applications")
                .appendingPathComponent(currentAppURL.lastPathComponent)
        }

        // 创建临时脚本
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwallowScreen_update_\(UUID().uuidString).sh")

        let scriptContent: String
        switch fileExtension {
        case "dmg":
            scriptContent = makeDMGScript(
                pid: currentPID,
                dmgPath: downloadURL.path,
                targetAppPath: targetAppURL.path
            )
        case "zip":
            scriptContent = makeZipScript(
                pid: currentPID,
                zipPath: downloadURL.path,
                targetAppPath: targetAppURL.path
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

        // 后台执行脚本
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

    // MARK: - 脚本生成

    /// 生成 DMG 格式的安装重启脚本
    private func makeDMGScript(pid: Int32, dmgPath: String, targetAppPath: String) -> String {
        """
        #!/bin/bash
        # 等待当前进程退出
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.5
        done

        # 挂载 DMG（-nobrowse 避免在 Finder 侧边栏显示）
        MOUNT_OUTPUT=$(hdiutil attach "\(dmgPath)" -nobrowse -noverify -noautoopen 2>&1)
        MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | tail -1 | awk '{print $NF}')

        if [ -z "$MOUNT_POINT" ]; then
            echo "挂载 DMG 失败" >&2
            exit 1
        fi

        # 查找 .app
        APP_PATH=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" -type d | head -1)

        if [ -z "$APP_PATH" ]; then
            hdiutil detach "$MOUNT_POINT" -quiet
            echo "DMG 中未找到 .app" >&2
            exit 1
        fi

        # 删除旧版本并复制新版本
        rm -rf "\(targetAppPath)"
        cp -R "$APP_PATH" "\(targetAppPath)"

        # 卸载 DMG
        hdiutil detach "$MOUNT_POINT" -quiet

        # 启动新版本
        open "\(targetAppPath)"

        # 清理脚本自身
        rm -f "$0"
        """
    }

    /// 生成 ZIP 格式的安装重启脚本
    private func makeZipScript(pid: Int32, zipPath: String, targetAppPath: String) -> String {
        """
        #!/bin/bash
        # 等待当前进程退出
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.5
        done

        # 解压 ZIP 到临时目录
        TMP_DIR=$(mktemp -d)
        unzip -q "\(zipPath)" -d "$TMP_DIR"

        # 查找 .app
        APP_PATH=$(find "$TMP_DIR" -name "*.app" -type d | head -1)

        if [ -z "$APP_PATH" ]; then
            rm -rf "$TMP_DIR"
            echo "ZIP 中未找到 .app" >&2
            exit 1
        fi

        # 删除旧版本并复制新版本
        rm -rf "\(targetAppPath)"
        cp -R "$APP_PATH" "\(targetAppPath)"

        # 清理临时目录
        rm -rf "$TMP_DIR"

        # 启动新版本
        open "\(targetAppPath)"

        # 清理脚本自身
        rm -f "$0"
        """
    }
}
