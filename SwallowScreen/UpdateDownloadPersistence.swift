//
//  UpdateDownloadPersistence.swift
//  SwallowScreen
//
//  下载文件落盘：将 URLSession 临时文件同步转移到持久目录
//

import Foundation

/// 下载文件的持久化落盘（纯文件操作，供单元测试独立编译）
public enum UpdateDownloadPersistence {

    /// 将下载临时文件移动到目标位置（目标已有旧文件时先清理再移动）
    /// - Parameters:
    ///   - location: URLSession 提供的临时文件地址
    ///     （delegate 方法返回后系统即删除，必须在 delegate 内同步处理）
    ///   - destinationURL: 目标文件地址
    /// - Throws: 移动失败时抛出底层错误，由调用方决定如何呈现
    /// - Note: 显式 nonisolated——Xcode 工程默认隔离为 MainActor，隐式隔离会使
    ///   URLSession delegate 的 nonisolated 回调无法同步调用（纯文件 IO 与线程无关）
    public nonisolated static func persistDownloadedFile(at location: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        // 清理目标处可能的旧残留，避免 moveItem 因目标已存在而失败
        try? fileManager.removeItem(at: destinationURL)
        // 同卷 rename 原子近似零耗时，不会阻塞主线程
        try fileManager.moveItem(at: location, to: destinationURL)
    }
}
