//
//  UpdateDownloadPersistenceTests.swift
//  SwallowScreenTests
//
//  下载文件落盘（临时文件同步转移）的单元测试
//

import XCTest
@testable import SwallowScreenCore

final class UpdateDownloadPersistenceTests: XCTestCase {

    private var tempDir: URL!
    private var sourceURL: URL!
    private var destURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateDownloadPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sourceURL = tempDir.appendingPathComponent("CFNetworkDownload_tmp")
        destURL = tempDir.appendingPathComponent("SwallowScreen-v1.0.25-universal.dmg")
        try Data("dmg-content".utf8).write(to: sourceURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // 契约 1：move 成功 —— 目标存在且内容一致，源文件消失
    func testPersistMovesFileToDestination() throws {
        try UpdateDownloadPersistence.persistDownloadedFile(at: sourceURL, to: destURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
        XCTAssertEqual(try Data(contentsOf: destURL), Data("dmg-content".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    // 契约 2：目标处预存旧文件时被新内容覆盖（先清理再移动）
    func testPersistOverwritesStaleDestination() throws {
        try Data("stale-old-content".utf8).write(to: destURL)

        try UpdateDownloadPersistence.persistDownloadedFile(at: sourceURL, to: destURL)

        XCTAssertEqual(try Data(contentsOf: destURL), Data("dmg-content".utf8))
    }

    // 契约 3：源文件不存在（已被系统回收）时抛错，不吞错
    func testPersistThrowsWhenSourceMissing() {
        try? FileManager.default.removeItem(at: sourceURL)

        XCTAssertThrowsError(try UpdateDownloadPersistence.persistDownloadedFile(at: sourceURL, to: destURL))
    }
}
