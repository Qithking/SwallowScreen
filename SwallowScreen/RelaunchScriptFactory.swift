//
//  RelaunchScriptFactory.swift
//  SwallowScreen
//
//  自更新安装脚本工厂（纯字符串生成，无 UI 依赖，供单元测试独立编译）
//
//  bug-58 加固要点（对应线上"安装并重启"失败问题）：
//  1. 安装前预检更新文件存在，缺失时快速失败（旧脚本引用了不存在的 DMG）
//  2. 挂载点按 /Volumes/ 前缀提取——旧实现 `tail -1 | awk '{print $NF}'` 会把
//     attach 失败信息误解析为挂载点，守卫失效后静默 exit 1
//  3. 全链路日志落盘 relaunch.log，失败不再静默
//  4. 清除 quarantine——GUI 应用派生的孤儿脚本执行 hdiutil attach 时
//     会被 Gatekeeper 拦截（与 Sparkle 自更新同款处理）
//  5. 等待原进程退出带 30s 超时（防 pid 复用导致死等）
//  6. open 带 3 次重试——紧跟 mv/detach 的 open 因 LaunchServices 异步刷新
//     滞后会确定性失败
//

import Foundation

public enum RelaunchScriptFactory {

    // MARK: - 对外接口

    /// 生成 DMG 格式的安装重启脚本
    public static func makeDMGScript(
        pid: Int32, dmgPath: String, targetAppPath: String, logPath: String
    ) -> String {
        [
            prologue(pid: pid, sourcePath: dmgPath, targetAppPath: targetAppPath, logPath: logPath),
            sourceGuard(sourcePath: dmgPath),
            clearQuarantine(sourcePath: dmgPath),
            dmgMountSection(dmgPath: dmgPath),
            replaceAppSection(
                targetAppPath: targetAppPath,
                rollbackCleanup: "hdiutil detach \"$MOUNT_POINT\" -quiet"
            ),
            "hdiutil detach \"$MOUNT_POINT\" -quiet\nlog \"已卸载 DMG\"",
            epilogue(targetAppPath: targetAppPath),
        ].joined(separator: "\n\n")
    }

    /// 生成 ZIP 格式的安装重启脚本
    public static func makeZipScript(
        pid: Int32, zipPath: String, targetAppPath: String, logPath: String
    ) -> String {
        [
            prologue(pid: pid, sourcePath: zipPath, targetAppPath: targetAppPath, logPath: logPath),
            sourceGuard(sourcePath: zipPath),
            clearQuarantine(sourcePath: zipPath),
            zipExtractSection(zipPath: zipPath),
            replaceAppSection(
                targetAppPath: targetAppPath,
                rollbackCleanup: "rm -rf \"$TMP_DIR\""
            ),
            "rm -rf \"$TMP_DIR\"\nlog \"已清理临时解压目录\"",
            epilogue(targetAppPath: targetAppPath),
        ].joined(separator: "\n\n")
    }

    // MARK: - 脚本段落

    /// 开头：日志初始化 + 等待原进程退出（30s 超时）
    private static func prologue(
        pid: Int32, sourcePath: String, targetAppPath: String, logPath: String
    ) -> String {
        """
        #!/bin/bash
        # SwallowScreen 自更新脚本（自动生成）——失败保留脚本与日志供取证
        LOG_FILE="\(logPath)"
        LOG_DIR="$(dirname "$LOG_FILE")"
        mkdir -p "$LOG_DIR" 2>/dev/null || exit 1
        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

        log "===== 更新安装脚本启动 ====="
        log "更新文件: \(sourcePath)"
        log "目标应用: \(targetAppPath)"
        log "等待原进程退出: pid=\(pid)"

        # 等待当前进程退出（30s 超时，防止 pid 被系统复用导致死等）
        ELAPSED=0
        while kill -0 \(pid) 2>/dev/null; do
            if [ "$ELAPSED" -ge 30 ]; then
                log "等待原进程退出超时（30 秒），放弃本次更新"
                exit 1
            fi
            sleep 1
            ELAPSED=$((ELAPSED + 1))
        done
        log "原进程已退出"
        """
    }

    /// 预检：更新文件必须存在（旧 bug：引用不存在的 DMG 后 attach 静默失败）
    private static func sourceGuard(sourcePath: String) -> String {
        """
        if [ ! -f "\(sourcePath)" ]; then
            log "更新文件不存在，无法继续安装: \(sourcePath)"
            exit 1
        fi
        log "更新文件存在，大小 $(stat -f%z "\(sourcePath)") 字节"
        """
    }

    /// 清除 quarantine（应用自身经 HTTPS 下载的官方安装包；
    /// 孤儿脚本执行 hdiutil attach 会被 Gatekeeper 拦截）
    private static func clearQuarantine(sourcePath: String) -> String {
        """
        if xattr -p com.apple.quarantine "\(sourcePath)" >/dev/null 2>&1; then
            if xattr -d com.apple.quarantine "\(sourcePath)" 2>>"$LOG_FILE"; then
                log "已清除 quarantine 属性"
            else
                log "清除 quarantine 失败，继续尝试安装"
            fi
        fi
        """
    }

    /// DMG 段：挂载 + 按 /Volumes/ 前缀提取挂载点 + 查找 .app
    private static func dmgMountSection(dmgPath: String) -> String {
        """
        # 挂载 DMG（-nobrowse 避免在 Finder 侧边栏显示）
        MOUNT_OUTPUT=$(hdiutil attach "\(dmgPath)" -nobrowse -noverify -noautoopen 2>&1)
        log "hdiutil attach 原始输出:"
        echo "$MOUNT_OUTPUT" >> "$LOG_FILE"

        # 挂载点按 /Volumes/ 前缀提取——失败输出不含 /Volumes/，不会误判
        MOUNT_LINE=$(printf '%s\\n' "$MOUNT_OUTPUT" | grep '/Volumes/' | tail -1)
        if [ -z "$MOUNT_LINE" ]; then
            log "挂载 DMG 失败（原始输出见上）"
            exit 1
        fi
        MOUNT_POINT="/Volumes/${MOUNT_LINE##*/Volumes/}"
        log "挂载点: $MOUNT_POINT"

        # 查找 .app
        APP_PATH=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" -type d | head -1)
        if [ -z "$APP_PATH" ]; then
            hdiutil detach "$MOUNT_POINT" -quiet
            log "DMG 中未找到 .app"
            exit 1
        fi
        log "找到应用: $APP_PATH"
        """
    }

    /// ZIP 段：解压到临时目录 + 查找 .app
    private static func zipExtractSection(zipPath: String) -> String {
        """
        # 解压 ZIP 到临时目录
        TMP_DIR=$(mktemp -d)
        unzip -q "\(zipPath)" -d "$TMP_DIR"
        if [ $? -ne 0 ]; then
            rm -rf "$TMP_DIR"
            log "解压 ZIP 失败"
            exit 1
        fi

        APP_PATH=$(find "$TMP_DIR" -name "*.app" -type d | head -1)
        if [ -z "$APP_PATH" ]; then
            rm -rf "$TMP_DIR"
            log "ZIP 中未找到 .app"
            exit 1
        fi
        log "找到应用: $APP_PATH"
        """
    }

    /// 替换段：先复制到临时名，成功后再原子替换（避免 cp 失败导致应用丢失）
    private static func replaceAppSection(targetAppPath: String, rollbackCleanup: String) -> String {
        """
        # 先复制到临时名，复制成功后再原子替换
        rm -rf "\(targetAppPath).new" "\(targetAppPath).old"
        cp -R "$APP_PATH" "\(targetAppPath).new"
        if [ $? -ne 0 ]; then
            \(rollbackCleanup)
            rm -rf "\(targetAppPath).new"
            log "复制新版本失败，已保留旧版本"
            exit 1
        fi
        log "新版本复制完成"

        # 同卷 rename 原子替换，旧版本暂存 .old，新版本就位后删除
        mv "\(targetAppPath)" "\(targetAppPath).old" 2>/dev/null
        mv "\(targetAppPath).new" "\(targetAppPath)"
        rm -rf "\(targetAppPath).old"
        log "应用替换完成"
        """
    }

    /// 结尾：启动新版本（3 次重试）+ 成功后清理脚本自身
    private static func epilogue(targetAppPath: String) -> String {
        """
        # 启动新版本——LaunchServices 异步刷新滞后，紧跟 mv/detach 的 open
        # 会确定性失败，必须重试
        ATTEMPT=0
        until open "\(targetAppPath)"; do
            ATTEMPT=$((ATTEMPT + 1))
            if [ "$ATTEMPT" -ge 3 ]; then
                log "启动新版本失败（已重试 3 次）"
                exit 1
            fi
            log "open 失败，1 秒后重试（第 $ATTEMPT 次）"
            sleep 1
        done
        log "新版本已启动，更新完成"

        # 清理脚本自身（仅成功路径；失败保留脚本供取证）
        rm -f "$0"
        """
    }
}
