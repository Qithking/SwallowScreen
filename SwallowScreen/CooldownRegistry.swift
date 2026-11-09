//
//  CooldownRegistry.swift
//  SwallowScreen
//
//  冷却/进行中守卫统一注册表：单一键控实现，收敛各类冷却/守卫/延迟任务状态
//
//  key 约定（调用方遵守）：
//  - "move:<windowID>"   移动冷却（到期自动解除）
//  - "unhide:<ptr>"      unhide 重试（onExpire 携带恢复可见副作用）
//  - "moving:<windowID>" 搬动进行中守卫（hold/release 手动解除）
//  - "fsExit:<pid>"      退出全屏冷却
//  - "axFallback:..."    AX 兜底延迟搬窗任务
//  - "axTimeout:<pid>"   AXObserver 空闲超时任务
//
//  线程安全：deinit 是 nonisolated（可能在任意线程执行），故内部用 NSLock
//  保护字典；DispatchWorkItem.cancel 本身线程安全。
//

import Foundation

final class CooldownRegistry {

    private struct Entry {
        let workItem: DispatchWorkItem?  // nil = hold 型（手动 release）
        let seq: Int                     // 插入序号，供 removeOldest 按"最旧"排序
    }

    private var entries: [String: Entry] = [:]
    private var nextSeq: Int = 0
    private let lock = NSLock()

    // MARK: - 查询

    /// 键是否处于冷却/守卫中
    func isCoolingDown(_ key: String) -> Bool {
        return lock.withLock { entries[key] != nil }
    }

    /// 处于冷却中的键数量（可按谓词过滤，用于上限清理判断）
    func count(where predicate: ((String) -> Bool)? = nil) -> Int {
        return lock.withLock {
            guard let predicate = predicate else { return entries.count }
            return entries.keys.filter(predicate).count
        }
    }

    // MARK: - 写入

    /// hold 型守卫：无到期时间，必须由 release/cancel 手动解除
    func hold(_ key: String) {
        lock.withLock { insert(key, workItem: nil) }
    }

    /// hold 型守卫解除
    func release(_ key: String) {
        cancel(key)
    }

    /// 任务型冷却：插入条目并调度 workItem，到期自动移除条目后执行 onExpire
    /// 若同键已有条目，先取消旧 workItem 再替换
    func coolDown(_ key: String,
                  duration: TimeInterval,
                  onExpire: (() -> Void)? = nil,
                  queue: DispatchQueue = .main) {
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 仅当条目仍是本 workItem 时才移除——防止误删同键的新条目
            self.removeEntryIfCurrent(key, item: item)
            onExpire?()
        }
        let old: DispatchWorkItem? = lock.withLock {
            let old = entries.removeValue(forKey: key)?.workItem
            insert(key, workItem: item)
            return old
        }
        old?.cancel()
        queue.asyncAfter(deadline: .now() + duration, execute: item)
    }

    // MARK: - 移除

    /// 取消单个键（workItem 存在则一并 cancel）
    func cancel(_ key: String) {
        let item: DispatchWorkItem? = lock.withLock {
            entries.removeValue(forKey: key)?.workItem
        }
        item?.cancel()
    }

    /// 按谓词批量取消并移除（用于按 pid 前缀清理死键）
    func removeKeys(where predicate: (String) -> Bool) {
        let items: [DispatchWorkItem] = lock.withLock {
            var removed: [DispatchWorkItem] = []
            for key in entries.keys where predicate(key) {
                if let item = entries.removeValue(forKey: key)?.workItem {
                    removed.append(item)
                }
            }
            return removed
        }
        items.forEach { $0.cancel() }
    }

    /// 按插入顺序取消并移除最旧的 n 条（可按谓词过滤），返回实际移除数量
    @discardableResult
    func removeOldest(_ n: Int, where predicate: ((String) -> Bool)? = nil) -> Int {
        return lock.withLock {
            let candidates = entries
                .filter { predicate?($0.key) ?? true }
                .sorted { $0.value.seq < $1.value.seq }
                .prefix(n)
            var removedCount = 0
            for (key, entry) in candidates {
                entries.removeValue(forKey: key)
                entry.workItem?.cancel()
                removedCount += 1
            }
            return removedCount
        }
    }

    /// 取消并移除全部条目（stopMonitoring / deinit 使用）
    func cancelAll() {
        let items: [DispatchWorkItem] = lock.withLock {
            let items = entries.values.compactMap(\.workItem)
            entries.removeAll()
            return items
        }
        items.forEach { $0.cancel() }
    }

    // MARK: - 私有

    /// 调用方须已持锁
    private func insert(_ key: String, workItem: DispatchWorkItem?) {
        entries[key] = Entry(workItem: workItem, seq: nextSeq)
        nextSeq += 1
    }

    private func removeEntryIfCurrent(_ key: String, item: DispatchWorkItem) {
        lock.withLock {
            if entries[key]?.workItem === item {
                entries.removeValue(forKey: key)
            }
        }
    }
}
