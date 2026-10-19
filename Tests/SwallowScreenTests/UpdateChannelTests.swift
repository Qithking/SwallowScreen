//
//  UpdateChannelTests.swift
//  SwallowScreenTests
//
//  更新下载渠道转换的单元测试（swift test 运行）
//

import XCTest
@testable import SwallowScreenCore

final class UpdateChannelTests: XCTestCase {

    /// GitHub Releases browser_download_url 的典型形态
    private let githubDMG =
        "https://github.com/Qithking/SwallowScreen/releases/download/v1.2.0/SwallowScreen-v1.2.0-arm64.dmg"

    // 官网渠道：URL 原样返回（现网行为不变）
    func testOfficialChannelKeepsURLUnchanged() {
        XCTAssertEqual(UpdateChannel.github.resolveDownloadURL(githubDMG), githubDMG)
    }

    // 加速渠道：对 github.com 的 URL 加 gh-proxy 前缀
    func testProxyChannelPrependsPrefixToGitHubURL() {
        XCTAssertEqual(
            UpdateChannel.ghproxy.resolveDownloadURL(githubDMG),
            "https://gh-proxy.com/" + githubDMG
        )
    }

    // 加速渠道幂等：已带 gh-proxy 前缀的 URL 不重复加前缀
    func testProxyChannelIsIdempotent() {
        let alreadyProxied = "https://gh-proxy.com/" + githubDMG
        XCTAssertEqual(UpdateChannel.ghproxy.resolveDownloadURL(alreadyProxied), alreadyProxied)
    }

    // 加速渠道只代理 github.com：其他域名原样返回
    func testProxyChannelIgnoresNonGitHubHost() {
        let other = "https://example.com/path/file.dmg"
        XCTAssertEqual(UpdateChannel.ghproxy.resolveDownloadURL(other), other)
    }

    // 官网渠道对任意 URL 都原样返回
    func testOfficialChannelIgnoresAnyURL() {
        let other = "https://example.com/path/file.dmg"
        XCTAssertEqual(UpdateChannel.github.resolveDownloadURL(other), other)
    }

    // rawValue 反序列化：合法值还原枚举，脏数据返回 nil（调用方 ?? .github 兜底）
    func testRawValueDeserialization() {
        XCTAssertEqual(UpdateChannel(rawValue: "github"), .github)
        XCTAssertEqual(UpdateChannel(rawValue: "ghproxy"), .ghproxy)
        XCTAssertNil(UpdateChannel(rawValue: "unknown"))
    }
}
