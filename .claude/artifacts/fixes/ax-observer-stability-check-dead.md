# Bug: AXObserver 主路径搬窗后稳定性校验失效（startStabilityCheck guard 必然失败）

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-10-18

## Symptom
AXObserver 主检测路径（多数 App 最先命中）搬窗后，防回弹稳定性校验从未启动。窗口被搬动后若被 App 异步布局移回原屏，不会被纠正。仅 hideMoveUnhide 内嵌的 150ms Y 校验部分覆盖。

## Expected
AXObserver 命中路径与 CG/AX 轮询链（onWindowDetected）行为一致：搬窗后 0.12s 启动 startStabilityCheck（1.5-2s 内每 100ms 校验，发现回弹立刻再搬，连续 3 次稳定停止）。

## Reproduction
无自动化测试基建（无 testTarget；AX 窗口行为依赖真实 macOS 窗口系统），沿用**静态代码路径审查 + 构建验证**（与 window-visible-on-wrong-screen-first.md 一致）。

- 步骤（协议）:
  1. SwallowScreen 运行中，为某 App 配置 targetScreen
  2. 启动该 App，AXObserver 先于轮询链命中（主路径，日志「AXObserver 检测到新窗口」）
  3. 修复前：无「稳定性校验」相关行为——startStabilityCheck 开头 guard 直接 return
- 复现稳定性: 代码因果链静态确定（非间歇性）

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | handleAXWindowCreated 命中后立即移除 context，0.12s 后 startStabilityCheck 的 guard `activeDetections[pid]` 必然失败 | confirmed (root cause) | WindowMover.swift 修复前 L305-308 `context.cancel()` + `activeDetections.removeValue(forKey: pid)`；L315-317 延迟 0.12s 调 startStabilityCheck；L1340 `guard let context = activeDetections[pid] else { return }`——三段代码因果链闭合 |
| H2 | context 不存在是常态（AXObserver 路径不创建 context） | eliminated | handleAppLaunch L756 同步调用 earlyWindowCatcher，其 L1080-1081 创建 `activeDetections[pid]`——AXObserver 命中时 context 通常存在，只是被 H1 主动移除 |

## Root cause
handleAXWindowCreated 抄了「停止轮询」的意图，但用了 `context.cancel() + removeValue`（完全销毁）而非轮询链的 `stopDetectionTimers`（停 timer 保留 context）。context 被 `cancelDetectionContext` 式移除后，0.12s 后的 startStabilityCheck 开头 guard 找不到 context，直接 return——主路径的稳定性校验形同虚设。对比：CG/AX 轮询链 onWindowDetected 前置调用 stopDetectionTimers（L1112/L1149），context 保留在 activeDetections 中，校验正常启动。

## Fix
- 改动文件: `SwallowScreen/WindowMover.swift:304-309`（handleAXWindowCreated）
- 一句话改了什么: `context.cancel() + activeDetections.removeValue + stabilityCount.removeValue`（5 行）→ `stopDetectionTimers(pid: pid)`（1 行），与轮询链 onWindowDetected 模式完全一致
- 代码 diff 摘要:

```swift
// 修复前:
if let context = activeDetections[pid] {
    context.cancel()
    activeDetections.removeValue(forKey: pid)
}
stabilityCount.removeValue(forKey: pid)

// 修复后:
stopDetectionTimers(pid: pid)
```

- 安全性自检（与新代码路径一致性）:
  - stopDetectionTimers cancel cgTimer/axTimer → 轮询 handler 不再 fire（DispatchSourceTimer.cancel 后不再触发）；即使边界竞态 handler 已入队，L1100/L1134 `stopFlag.isSet` 检查 + cancelDetectionContext 自愈退出
  - stabilityTimer 在 fresh context 中必为 nil，stopDetectionTimers 不触碰它，无泄漏
  - stabilityCount[pid] 未在此处清零——startStabilityCheck L1341 `stabilityCount[pid] = 0` 显式重置，等价
  - PID 复用防御恢复：startStabilityCheck 事件循环 L1353 `context.isPIDStillOriginal()` 重新生效

## Verification
- V-1: 静态代码路径审查——修复后 AXObserver 命中路径与轮询链 onWindowDetected 路径对 startStabilityCheck 的前置条件完全一致（context 保留在 activeDetections）✓
- V-2: xcodebuild 构建两次（#1 修改后、#1+#2 全部修改后）均 ** BUILD SUCCEEDED ** ✓
- V-3: 手动验证（待用户）——启动已配置 targetScreen 的 App，观察搬窗后 App 若自行移窗，1.5-2s 内应被搬回

## Regression test
无自动化测试基建（同前两个 fix artifact 说明）。防回归依赖：修复后代码与轮询链模式的一致性（grep `stopDetectionTimers` 可见三处调用同模式）+ 上述手动验证协议。

## Pattern analysis
| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| `grep -n "activeDetections.removeValue"` WindowMover.swift | 6 处 | 否——其余 5 处均为 cancelDetectionContext / 超时 / 稳定命中 / PID 复用分支的**终态清理**（校验已结束或放弃），语义正确；仅本次修复点是「命中后仍需用 context」的中间态误清理 |

## Open questions / Follow-ups
- 全应用静态审查报告（.work/执行文档.md 问题14）中同链路的 P2 项 #7「startStabilityCheck 拓扑变化分支只 cancel timer 不清 context」仍在，属独立小泄漏，未在本次修复范围（外科手术式），由用户决定是否走 dev-fix
