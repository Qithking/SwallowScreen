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

    // MARK: - 契约：安装前文件预检（bug-58 第一层：路径不存在时快速失败）

    func testDMGScriptChecksFileExistsBeforeAttach() throws {
        let script = RelaunchScriptFactory.makeDMGScript(
            pid: 1234, dmgPath: dmgPath, targetAppPath: targetAppPath, logPath: logPath
        )
        XCTAssertTrue(
            script.contains("[ ! -f \"\(dmgPath)\" ]"),
            "挂载前必须预检 DMG 文件存在，缺失时直接退出"
        )
        // 预检必须发生在 attach 之前
        let guardIndex = try XCTSourceLocation(offsetOf: "[ ! -f \"\(dmgPath)\" ]", in: script)
        let attachIndex = try XCTSourceLocation(offsetOf: "hdiutil attach", in: script)
        XCTAssertLessThan(guardIndex, attachIndex, "文件预检必须先于 hdiutil attach")
    }

    func testZipScriptChecksFileExistsBeforeUnzip() {
        let script = RelaunchScriptFactory.makeZipScript(
            pid: 1234, zipPath: zipPath, targetAppPath: targetAppPath, logPath: logPath
        )
        XCTAssertTrue(
            script.contains("[ ! -f \"\(zipPath)\" ]"),
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
}

/// 辅助：在字符串中定位子串偏移（比 range 转换更直观）
private func XCTSourceLocation(offsetOf substring: String, in source: String) throws -> Int {
    guard let range = source.range(of: substring) else {
        throw NSError(domain: "RelaunchScriptFactoryTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "未找到子串: \(substring)"])
    }
    return source.distance(from: source.startIndex, to: range.lowerBound)
}
