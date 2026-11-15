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
//  7. 失败统一出口 fail()：应用此时已退出，失败只写日志用户面对消失的应用
//     零反馈——由脚本自身 osascript 弹窗告知
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

    /// bash 单引号字面量转义：包裹为 '...'，内部单引号转为 '\''
    /// 双引号内插的路径中 $(...)/反引号会被执行、" 会破坏语法——
    /// 下载文件名来自服务器（suggestedFilename），不可信，必须一律走本转义
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 开头：日志初始化 + 等待原进程退出（30s 超时）
    private static func prologue(
        pid: Int32, sourcePath: String, targetAppPath: String, logPath: String
    ) -> String {
        """
        #!/bin/bash
        # SwallowScreen 自更新脚本（自动生成）——失败保留脚本与日志供取证
        LOG_FILE=\(shellQuote(logPath))
        LOG_DIR="$(dirname "$LOG_FILE")"
        # 失败统一出口：写日志 + 弹窗告知 + 退出（定义在 mkdir 之前，保证全程可用）
        fail() {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 更新失败: $*" >> "$LOG_FILE" 2>/dev/null
            osascript -e "display dialog \\\"SwallowScreen 更新安装失败，详情见日志：\\\" & return & \\\"$LOG_FILE\\\" with title \\\"更新失败\\\" buttons {\\\"好\\\"} default button \\\"好\\\" with icon caution" >/dev/null 2>&1
            exit 1
        }
        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
        mkdir -p "$LOG_DIR" 2>/dev/null || fail "无法创建日志目录 $LOG_DIR"

        # 实例锁：双开并发更新会互删对方的 .old 回滚备份（最坏旧版本丢失）——
        # mkdir 原子创建保证同一时刻只有一个脚本在执行；EXIT trap 兜底清理锁
        LOCK_DIR="${LOG_DIR}/update.lock"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            fail "检测到另一个更新进程正在执行，本次更新已放弃"
        fi
        trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

        log "===== 更新安装脚本启动 ====="
        log "更新文件:" \(shellQuote(sourcePath))
        log "目标应用:" \(shellQuote(targetAppPath))
        log "等待原进程退出: pid=\(pid)"

        # 等待当前进程退出（30s 超时，防止 pid 被系统复用导致死等）
        ELAPSED=0
        while kill -0 \(pid) 2>/dev/null; do
            if [ "$ELAPSED" -ge 30 ]; then
                fail "等待原进程退出超时（30 秒），放弃本次更新"
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
        if [ ! -f \(shellQuote(sourcePath)) ]; then
            fail "更新文件不存在，无法继续安装:" \(shellQuote(sourcePath))
        fi
        log "更新文件存在，大小 $(stat -f%z \(shellQuote(sourcePath))) 字节"
        """
    }

    /// 清除 quarantine（应用自身经 HTTPS 下载的官方安装包；
    /// 孤儿脚本执行 hdiutil attach 会被 Gatekeeper 拦截）
    private static func clearQuarantine(sourcePath: String) -> String {
        """
        if xattr -p com.apple.quarantine \(shellQuote(sourcePath)) >/dev/null 2>&1; then
            if xattr -d com.apple.quarantine \(shellQuote(sourcePath)) 2>>"$LOG_FILE"; then
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
        MOUNT_OUTPUT=$(hdiutil attach \(shellQuote(dmgPath)) -nobrowse -noverify -noautoopen 2>&1)
        log "hdiutil attach 原始输出:"
        echo "$MOUNT_OUTPUT" >> "$LOG_FILE"

        # 挂载点按 /Volumes/ 前缀提取——失败输出不含 /Volumes/，不会误判
        MOUNT_LINE=$(printf '%s\\n' "$MOUNT_OUTPUT" | grep '/Volumes/' | tail -1)
        if [ -z "$MOUNT_LINE" ]; then
            fail "挂载 DMG 失败（原始输出见上）"
        fi
        MOUNT_POINT="/Volumes/${MOUNT_LINE##*/Volumes/}"
        log "挂载点: $MOUNT_POINT"

        # 查找 .app
        APP_PATH=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" -type d | head -1)
        if [ -z "$APP_PATH" ]; then
            hdiutil detach "$MOUNT_POINT" -quiet
            fail "DMG 中未找到 .app"
        fi
        log "找到应用: $APP_PATH"
        """
    }

    /// ZIP 段：解压到临时目录 + 查找 .app
    private static func zipExtractSection(zipPath: String) -> String {
        """
        # 解压 ZIP 到临时目录
        TMP_DIR=$(mktemp -d)
        unzip -q \(shellQuote(zipPath)) -d "$TMP_DIR"
        if [ $? -ne 0 ]; then
            rm -rf "$TMP_DIR"
            fail "解压 ZIP 失败"
        fi

        APP_PATH=$(find "$TMP_DIR" -name "*.app" -type d | head -1)
        if [ -z "$APP_PATH" ]; then
            rm -rf "$TMP_DIR"
            fail "ZIP 中未找到 .app"
        fi
        log "找到应用: $APP_PATH"
        """
    }

    /// 替换段：先复制到临时名，成功后再原子替换（避免 cp 失败导致应用丢失）
    private static func replaceAppSection(targetAppPath: String, rollbackCleanup: String) -> String {
        // .new/.old 后缀先拼好再整体转义；log 中的路径作为独立参数（拆出双引号文本），
        // 否则双引号内的单引号无法阻止 $(...) 展开
        let tApp = shellQuote(targetAppPath)
        let tNew = shellQuote(targetAppPath + ".new")
        let tOld = shellQuote(targetAppPath + ".old")
        return """
        # 先复制到临时名，复制成功后再原子替换
        rm -rf \(tNew) \(tOld)
        cp -R "$APP_PATH" \(tNew)
        if [ $? -ne 0 ]; then
            \(rollbackCleanup)
            rm -rf \(tNew)
            fail "复制新版本失败，已保留旧版本"
        fi
        log "新版本复制完成"

        # 同卷 rename 原子替换，旧版本暂存 .old，新版本就位后删除
        mv \(tApp) \(tOld) 2>>"$LOG_FILE"
        if [ $? -ne 0 ]; then
            # 第一步失败时 target 未动，清掉 .new 即可，原版本完好
            \(rollbackCleanup)
            rm -rf \(tNew)
            fail "旧版本改名失败，已保留原版本"
        fi
        mv \(tNew) \(tApp) 2>>"$LOG_FILE"
        if [ $? -ne 0 ]; then
            # 第二步失败时 target 已移到 .old：先清理挂载/临时资源再移回恢复旧版本，
            # 即使恢复也失败也绝不删除 .old——它是唯一的完整旧版本
            \(rollbackCleanup)
            mv \(tOld) \(tApp) 2>>"$LOG_FILE"
            if [ $? -eq 0 ]; then
                fail "新版本替换失败，已恢复旧版本（新版本暂存于" \(tNew)
            else
                fail "新版本替换失败且恢复失败——完整旧版本暂存在" \(tOld) "，请手动移回"
            fi
        fi
        rm -rf \(tOld)
        log "应用替换完成"
        """
    }

    /// 结尾：启动新版本（3 次重试）+ 成功后清理脚本自身
    private static func epilogue(targetAppPath: String) -> String {
        """
        # 启动新版本——LaunchServices 异步刷新滞后，紧跟 mv/detach 的 open
        # 会确定性失败，必须重试
        ATTEMPT=0
        until open \(shellQuote(targetAppPath)); do
            ATTEMPT=$((ATTEMPT + 1))
            if [ "$ATTEMPT" -ge 3 ]; then
                fail "启动新版本失败（已重试 3 次）"
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
