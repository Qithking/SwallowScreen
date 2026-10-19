//
//  UpdateChannel.swift
//  SwallowScreen
//
//  更新下载渠道 - 决定更新包从 GitHub 官网直连还是经加速镜像下载
//

import Foundation

/// 更新下载渠道
/// - github: GitHub 官网直连（默认，与既有行为一致）
/// - ghproxy: GitHub 加速镜像（gh-proxy.com 前缀代理）
enum UpdateChannel: String, CaseIterable {

    case github
    case ghproxy

    /// gh-proxy 加速服务的 URL 前缀（该服务标准用法：前缀 + 完整原始 URL）
    private static let proxyPrefix = "https://gh-proxy.com/"

    /// 按渠道解析下载地址
    /// - github: 任意 URL 原样返回
    /// - ghproxy: 仅对 github.com 域名加前缀；其余域名（含已带前缀的
    ///   gh-proxy.com URL，天然幂等）原样返回
    func resolveDownloadURL(_ urlString: String) -> String {
        guard self == .ghproxy,
              let url = URL(string: urlString),
              url.host == "github.com" else {
            return urlString
        }
        return Self.proxyPrefix + urlString
    }
}
