//
//  RelaunchScriptFactoryTests.swift
//  SwallowScreenTests
//
//  自更新安装脚本的加固契约测试（bug-58 安装重启失败修复）
//
//  背景：线上脚本存在 4 层缺陷 —— ①文件缺失无预检 ②hdiutil attach 失败时
//  `tail -1 | awk '{print $NF}'` 把错误信息误解析为挂载点 ③全程无日志落盘、
//  失败静默 ④等待循环无超时、open 无重试。本测试锁定生成的 bash 脚本必须
//  具备的防御行为。
//

import XCTest
@testable import SwallowScreenCore

final class RelaunchScriptFactoryTests: XCTestCase {

    private let dmgPath = "/tmp/RelaunchScriptFactoryTests/SwallowScreen-v1.0.31-universal.dmg"
    private let zipPath = "/tmp/RelaunchScriptFactoryTests/SwallowScreen-v1.0.31-universal.zip"
    private let targetAppPath = "/Applications/SwallowScreen.app"
    private let logPath = "/tmp/RelaunchScriptFactoryTests/SwallowScreenUpdates/relaunch.log"

    // MARK: - bash 语法校验（模板改动最易产生语法错误）

    private func assertBashSyntaxValid(_ script: String, label: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n"]
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(script.data(using: .utf8)!)
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "\(label) 语法错误: \(errOutput)")
    }

    func testDMGScriptSyntaxValid() throws {
        let script = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        try assertBashSyntaxValid(script, label: "DMG 脚本")
    }

    func testZipScriptSyntaxValid() throws {
        let script = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
        )
        try assertBashSyntaxValid(script, label: "ZIP 脚本")
    }

    // MARK: - 契约：失败必须弹窗告知（应用已退出，脚本失败不能只写日志静默消失）

    func testScriptsAlertUserOnFailure() throws {
        for (script, label) in [
            (RelaunchScriptFactory.makeDMGScript(
                pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
            ), "DMG"),
            (RelaunchScriptFactory.makeZipScript(
                pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
            ), "ZIP"),
        ] {
            XCTAssertTrue(script.contains("fail()"), "\(label) 脚本必须有统一失败出口 fail()")
            XCTAssertTrue(
                script.contains("osascript") && script.contains("display dialog"),
                "\(label) 脚本失败必须 osascript 弹窗告知用户"
            )
            // 各失败点必须走 fail() 而非裸 exit 1——exit 1 只允许出现在 fail() 函数体内
            let allLines = script.split(separator: "\n")
            guard let failStart = allLines.firstIndex(where: { $0.contains("fail() {") }),
                  let failEnd = allLines[failStart...].firstIndex(where: {
                      $0.trimmingCharacters(in: .whitespaces) == "}"
                  }) else {
                XCTFail("\(label) 脚本缺少 fail() 定义")
                return
            }
            let bareExits = allLines.enumerated().filter {
                ($0.offset < failStart || $0.offset > failEnd) && $0.element.contains("exit 1")
            }
            XCTAssertTrue(
                bareExits.isEmpty,
                "\(label) 脚本存在 fail() 之外的裸 exit 1（用户零反馈）: \(bareExits.map { $0.element })"
            )
        }
    }

    // MARK: - 契约：安装前文件预检（bug-58 第一层：路径不存在时快速失败）

    func testDMGScriptChecksFileExistsBeforeAttach() throws {
        let script = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        XCTAssertTrue(
            script.contains("[ ! -f '\(dmgPath)' ]"),
            "挂载前必须预检 DMG 文件存在，缺失时直接退出"
        )
        // 预检必须发生在 attach 之前
        let guardIndex = try XCTSourceLocation(offsetOf: "[ ! -f '\(dmgPath)' ]", in: script)
        let attachIndex = try XCTSourceLocation(offsetOf: "hdiutil attach", in: script)
        XCTAssertLessThan(guardIndex, attachIndex, "文件预检必须先于 hdiutil attach")
    }

    func testZipScriptChecksFileExistsBeforeUnzip() {
        let script = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
        )
        XCTAssertTrue(
            script.contains("[ ! -f '\(zipPath)' ]"),
            "解压前必须预检 ZIP 文件存在，缺失时直接退出"
        )
    }

    // MARK: - 契约：quarantine 清除（bug-58：Gatekeeper 拦截孤儿进程的 attach）

    func testScriptsRemoveQuarantineBeforeInstall() {
        let dmgScript = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        let zipScript = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
        )
        XCTAssertTrue(dmgScript.contains("com.apple.quarantine"), "DMG 脚本必须清除 quarantine")
        XCTAssertTrue(zipScript.contains("com.apple.quarantine"), "ZIP 脚本必须清除 quarantine")
    }

    // MARK: - 契约：挂载点解析修复（attach 失败输出被 awk $NF 误解析为挂载点）

    func testDMGScriptParsesMountPointByVolumesPrefix() {
        let script = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        XCTAssertTrue(
            script.contains("/Volumes/"),
            "挂载点必须按 /Volumes/ 前缀提取，错误信息不会产生误判"
        )
        XCTAssertFalse(
            script.contains("awk '{print $NF}'"),
            "禁止沿用旧的 $NF 解析——attach 失败输出 'attach failed - No such file or directory' "
                + "会被解析出挂载点 'directory'，守卫失效"
        )
    }

    // MARK: - 契约：全链路日志落盘（失败不再静默）

    func testScriptsWriteLogThroughout() {
        let dmgScript = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        let zipScript = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
        )
        for (script, label) in [(dmgScript, "DMG"), (zipScript, "ZIP")] {
            XCTAssertTrue(script.contains(logPath), "\(label) 脚本必须写入指定日志文件")
            XCTAssertTrue(script.contains("mkdir -p"), "\(label) 脚本必须确保日志目录存在")
            XCTAssertTrue(script.contains("hdiutil attach") || script.contains("unzip"),
                          "\(label) 脚本关键命令输出必须落盘")
        }
    }

    // MARK: - 契约：等待退出有超时上限（防 pid 复用死等）

    func testWaitLoopHasTimeout() {
        let dmgScript = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        let zipScript = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
        )
        for (script, label) in [(dmgScript, "DMG"), (zipScript, "ZIP")] {
            XCTAssertTrue(script.contains("-ge 30"), "\(label) 等待循环必须有 30s 超时上限")
        }
    }

    // MARK: - 契约：open 重试（LaunchServices 异步刷新滞后，紧跟 mv/detach 的 open 100% 失败）

    func testOpenHasRetryLoop() {
        let dmgScript = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        let zipScript = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
        )
        for (script, label) in [(dmgScript, "DMG"), (zipScript, "ZIP")] {
            XCTAssertTrue(script.contains("until open"), "\(label) 启动新版本必须带重试")
            XCTAssertTrue(script.contains("sleep 1"), "\(label) 重试之间必须间隔 1s")
        }
    }

    // MARK: - 契约：mv 两步替换必须各自带错误守卫
    // （mv② 失败后无条件 rm -rf .old 会删掉唯一旧版本备份，应用丢失且无法恢复）

    func testReplaceSectionGuardsBothMvStepsAndKeepsRollback() throws {
        let zipScript = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
        )
        let dmgScript = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        for (script, label) in [(zipScript, "ZIP"), (dmgScript, "DMG")] {
            // 第一步 mv（改名暂存 .old）必须有守卫——失败时 target 原样保留
            let firstMv = try XCTSourceLocation(
                offsetOf: "mv '\(targetAppPath)' '\(targetAppPath).old'", in: script
            )
            let firstGuard = try XCTSourceLocation(offsetOf: "旧版本改名失败", in: script)
            XCTAssertLessThan(firstMv, firstGuard, "\(label) 第一步 mv 必须有错误守卫")

            // 第二步 mv（.new 就位）必须有守卫，且失败路径先移回 .old 恢复旧版本
            let secondMv = try XCTSourceLocation(
                offsetOf: "mv '\(targetAppPath).new' '\(targetAppPath)'", in: script
            )
            let restoreMv = try XCTSourceLocation(
                offsetOf: "mv '\(targetAppPath).old' '\(targetAppPath)'", in: script
            )
            XCTAssertLessThan(firstGuard, secondMv, "\(label) 第二步 mv 必须在第一步守卫之后")
            XCTAssertLessThan(
                secondMv, restoreMv, "\(label) 第二步 mv 失败必须先移回 .old 恢复旧版本"
            )

            // rm -rf ".old"（独立一行，不含 .new 的开头清理行）必须在恢复路径之后——
            // 任何失败分支都不得触达删除 .old 的语句
            let finalRm = try XCTSourceLocation(
                offsetOf: "rm -rf '\(targetAppPath).old'", in: script
            )
            XCTAssertLessThan(
                restoreMv, finalRm, "\(label) 删除 .old 必须仅在两步 mv 均成功的路径上"
            )
        }
    }

    // MARK: - 契约：路径一律 shell 单引号转义（suggestedFilename 不可信）

    // 下载文件名来自服务器（Content-Disposition），含 $(...) 时双引号内插会被执行
    // （命令注入），含 " 时破坏脚本语法——所有路径必须走 shellQuote 单引号字面量

    func testPathsAreShellQuotedAgainstInjection() throws {
        let evil = "/tmp/evil $(touch /tmp/SwallowScreenC3Pwned) te'st\"x.dmg"
        let dmgScript = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: evil, targetAppPath: targetAppPath, logPath: logPath
        )
        let zipScript = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: evil, targetAppPath: targetAppPath, logPath: logPath
        )
        // 危险路径必须以单引号字面量出现：' 转为 '\' 后 $( ) " 均为纯文本
        let expectedQuoted = "'/tmp/evil $(touch /tmp/SwallowScreenC3Pwned) te'\\''st\"x.dmg'"
        XCTAssertTrue(dmgScript.contains(expectedQuoted), "DMG 路径必须单引号字面量转义")
        XCTAssertTrue(zipScript.contains(expectedQuoted), "ZIP 路径必须单引号字面量转义")
        // 禁止双引号直接内插残留
        XCTAssertFalse(dmgScript.contains("\"\(evil)\""), "禁止双引号内插 DMG 路径")
        XCTAssertFalse(zipScript.contains("\"\(evil)\""), "禁止双引号内插 ZIP 路径")
        // targetAppPath / logPath 同样必须转义
        for (script, label) in [(dmgScript, "DMG"), (zipScript, "ZIP")] {
            XCTAssertTrue(script.contains("'\(targetAppPath)'"), "\(label) targetAppPath 必须转义")
            XCTAssertTrue(script.contains("'\(logPath)'"), "\(label) logPath 必须转义")
            // 含 ' 与 " 的路径不得破坏 bash 语法
            try assertBashSyntaxValid(script, label: "\(label) 危险路径脚本")
        }
    }
}

/// 辅助：在字符串中定位子串偏移（比 range 转换更直观）
private func XCTSourceLocation(offsetOf substring: String, in source: String) throws -> Int {
    guard let range = source.range(of: substring) else {
        throw NSError(domain: "RelaunchScriptFactoryTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "未找到子串: \(substring)"])
    }
    return source.distance(from: source.startIndex, to: range.lowerBound)
}
