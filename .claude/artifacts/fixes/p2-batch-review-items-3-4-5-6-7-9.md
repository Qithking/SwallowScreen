# Fix: 审查报告 P2 批量修复 #3/#4/#5/#6/#7/#9（问题17）

**Status**: FIXED
**Date**: 2026-10-18
**Scope**: WindowMover.swift（6 处）、ScreenManager.swift（1 行注释）
**来源**: 全应用静态审查报告（问题14）剩余 P2 项，用户决策合并修复 #3/#4/#7（同族资源管理）并处理 #5/#6/#9

---

## 逐项记录

### #3 axFallbackWorkItems 无界增长
- **Symptom**: 每次 App 启动 append 3 个 DispatchWorkItem（L805），执行完成后从数组移除的唯一途径是 stopMonitoring 全量 removeAll——频繁启动 App 时数组只增不减
- **Root cause**: workItem 执行体无自清理逻辑，已完成的 item 对象被数组长期持有
- **Fix**: `var weakItem: DispatchWorkItem?` 弱引用自身 + 闭包 `defer` 中 `axFallbackWorkItems.removeAll { $0 === it }`——无论命中/跳过/提前 return，执行完成即自清理。weakItem 弱引用避免 item→closure→item 循环持有；未执行即 cancel 的路径（stopMonitoring/deinit）仍由 removeAll 兜底
- **Verification**: 静态审查 + xcodebuild 构建通过

### #4 AXObserver 标题不匹配永久挂起
- **Symptom**: handleAXWindowCreated 标题不匹配时直接 return（不取消 observer），若 windowTitlePattern 配错或 App 永不再创建匹配窗口，observer + pendingAXObservations[pid] 永久残留（runloop source 常驻）
- **Root cause**: 原设计「等待后续窗口创建」无生命周期上限；App 退出有 handleAppTermination 兜底，但「App 存活 + 永不匹配」场景无防御
- **Fix**: 空闲超时机制（15s）——`scheduleAXObserverTimeout(for:)` 调度/刷新超时 workItem，到期时 pendingAXObservations[pid] 仍在则 removeAXObserver + 清 observation；4 个接线点：
  1. setupAXObserver 注册成功后调度（启动路径）
  2. handleAXWindowCreated 标题不匹配分支刷新计时（最后一次事件后 15s 无匹配才清理）
  3. handleAXWindowCreated 命中分支 cancelAXObserverTimeout（正常清理）
  4. handleAppTermination cancel（App 退出）
  - stopMonitoring / deinit 同步全量清理 axObserverTimeoutItems
- **Verification**: 静态审查（超时清理与命中清理/App 退出清理三路互斥不冲突）+ xcodebuild 构建通过
- **备注**: 误杀影响可控——observer 被超时清理后若真创建匹配窗口，CG/AX 轮询链与 fallback 搬窗仍在运行

### #5 pinWindowSizeCache 无失效
- **Symptom**: 缓存写入后永不更新（唯一写入点首次读取时），窗口 resize 后仍用陈旧尺寸——isBoundsInTargetFrame 中心点判定偏差 + 搬动 prebuiltSize 用旧尺寸导致居中偏移
- **Root cause**: 缓存值无过期机制；现有失效点（App 卸载/位置读取失败/屏拓扑变化/stopMonitoring）均不覆盖「App 存活期间 resize」场景
- **Fix**: 缓存值改为元组 `(size: CGSize, cachedAt: Date)` + TTL 5s（`pinWindowSizeCacheTTL`）——超过 5s 强制重读 AX size 并刷新缓存；removeAll/removeValue 触点类型无关无需改动
- **Verification**: grep 确认全部 12 处触点类型一致 + xcodebuild 构建通过

### #6 scheduleAXFallbackMove 缺 PID 复用防御
- **Symptom**: fallback workItem fire 时仅检查进程存在（`NSRunningApplication(pid) != nil`）——旧 App 退出后 PID 被复用给新 App 时，新 App 窗口会被搬到旧 App 的 targetFrame
- **Root cause**: 与 onWindowDetected（CG/AX 链）的 isPIDStillOriginal 防御不对称，fallback 链缺 launchDate 校验
- **Fix**: scheduleAXFallbackMove 新增 `launchDate: Date? = nil` 参数，调度时刻快照 `NSRunningApplication(processIdentifier: pid)?.launchDate`；fire 时进程存在且 launchDate 与快照一致才继续（与 DetectionContext.isPIDStillOriginal 的 nil 兼容分支语义一致）
- **Verification**: 静态审查 + xcodebuild 构建通过

### #7 startStabilityCheck 拓扑分支不清 context
- **Symptom**: 稳态校验中目标屏拓扑变化分支（`isTargetScreenAvailable` 失败）只 cancel timer——context 残留 activeDetections、stabilityCount 残留
- **Root cause**: 与超时分支（清 context + stabilityCount）、稳定分支（同清）不对称
- **Fix**: 拓扑分支补齐 `stabilityTimer = nil + activeDetections.removeValue + stabilityCount.removeValue`，与另两分支完全对称
- **Verification**: 静态审查 + xcodebuild 构建通过

### #9 getScreenContainingPoint dead code
- **Symptom/Root cause**: 全库零调用（grep 确认），纯死代码
- **Fix**: 删除函数（16 行）；ScreenManager.swift L94 注释同步微调（原注释引用该函数，避免悬空引用）
- **Verification**: xcodebuild 构建通过

---

## Verification 汇总

- **构建**: Xcode xcodebuild `-project SwallowScreen.xcodeproj -scheme SwallowScreen -configuration Debug build` → BUILD SUCCEEDED（linter 17 处 SwiftData 假错误为历史已知问题，CommandLineTools 缺宏插件，与修改无关）
- **单测**: 主 App 无 testTarget，AX/GUI 集成逻辑无法单测——沿用既往验证策略（构建 + 静态代码路径审查 + 手动验证协议）

## Pattern analysis

- #3/#4/#6 同属「异步任务生命周期无上限」模式：workItem/observer 创建后依赖外部事件清理，缺时间上限。修复模式统一为「空闲超时自清理」或「执行完成自清理」
- #7 与既有问题15 同族（context 生命周期管理），activeDetections 的清理分支现已三路对称（超时/稳定/拓扑）+ PID 复用 + App 退出，共 5 路防御
- 审查报告其余 rm -rf/字典类触点复查均无同类隐患（已在前两批 artifact 中覆盖）

## Follow-ups

- 手动验证协议（见 .work/执行文档.md 问题17）：
  1. 启动已配置 targetScreen 的 App → 正常搬窗（回归，覆盖 #6 launchDate 快照路径）
  2. 修改某 App 的 windowTitlePattern 为不可能匹配的值 → 启动该 App → 约 15s 后日志出现「AXObserver 空闲超时，清理观察者」（#4 验证；验证后恢复 pattern）
  3. 拖动/resize 窗口后 5s 内 pinToScreen 回弹位置正确（#5 验证）
  4. （可选）启动/退出 App 多次后 stopMonitoring（重启 SwallowScreen）无异常（#3 回归）
- P2 #8（CG 链逐 App 全量快照优化）仍待用户决策——涉及轮询主路径，需单独评估
