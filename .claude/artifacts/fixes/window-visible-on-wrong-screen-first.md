# Bug: 部分应用启动时窗口先在其他屏幕显示，之后才被搬到目标屏幕

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-10-18

## Symptom
部分应用（如微信）启动时，窗口先在错误屏幕（默认屏）可见停留一段时间，然后才被移动到配置的目标屏幕。用户看到「先初始到其他屏幕 → 再移动到目标屏幕」的完整过程。

## Expected
应用窗口应尽可能直接出现在目标屏幕；受 macOS 跨进程限制无法在首帧渲染前拦截时，「在错误屏可见」的时长应尽量短（不可感知量级）。

## Reproduction
无自动化测试基建（无 testTarget；AX 窗口行为依赖真实 macOS 窗口系统），沿用**手动复现协议 + 构建验证**（与 pin-new-window-not-moved.md 一致）。

- 步骤（协议）:
  1. SwallowScreen 运行中，为微信配置 pinToScreen/targetScreen 到非默认屏的某个屏幕
  2. 完全退出微信，重新启动
  3. 观察：微信主窗口先在默认屏可见 ~0.5-1.5s，然后跳到目标屏（bug 现象）
- 复现稳定性: 用户报告稳定复现，仅「部分应用」（微信类）

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | 检测延迟窗口：微信类 App 启动初期窗口对前三条检测链不可见（不发 created 通知 / CG 过滤条件排除 / AX 属性未就绪），最早命中点是 fallback 第一档 0.5s → 错误屏可见期 0.5~1.5s | confirmed (root cause) | WindowMover.swift L758-759 注释直接背书「部分 App（如微信）启动时 AXObserver/CGWindowList 都检测不到窗口，但在几百 ms 后 AX 窗口属性可用」；scheduleAXFallbackMove L766 delays=[0.5, 1.5]；setupAXObserver L226（事件驱动但依赖 App 发通知）；findOnScreenWindow L920 过滤条件（layer 0 / alpha>0 / ≥50px）；stabilityCheck L1367-1368 依赖 CG 可见性，微信类 CG 不可见期间同样空转 |
| H2 | move-only 可见搬动：不支持 AX hidden 属性的 App（hidden 设置失败）走 move-only，搬动过程本身可见 | confirmed (次因) | hideMoveUnhide L818-821：`hiddenSucceeded[window] = ok`，失败窗口直接 move 不尝试 unhide，日志「hidden=true 设置失败，该窗口将走 move-only」 |
| H3 | 上次快照截止窗口修复（createdSnapshotCutoff）放大了延迟 | eliminated | 快照截止只在 pinObserver 的 created 通道（handlePinWindowCreated 入口）生效；启动路径 axObservers / earlyWindowCatcher / scheduleAXFallbackMove 均不走该通道，且启动期 isPerformingInitialMove=true 时 handlePinWindowCreated 本就被 guard 拦截。与现象无关 |

## Root cause
窗口「在错误屏变为可见」与「检测链命中」之间存在**固有延迟窗口**。启动搬动四条链全部是事后检测：

| 链 | 机制 | 生效前提 | 命中延迟 |
|---|---|---|---|
| 1. AXObserver | 事件驱动（L226） | App 发 kAXWindowCreatedNotification | 首帧渲染后；微信等部分 App 不发 |
| 2. CG 轮询 33ms | L1088 | 窗口 on-screen 且满足过滤条件 | 33~66ms |
| 3. AX 轮询 100ms | L1123 | AX 窗口属性就绪 | ≥100ms |
| 4. AX fallback | L766 delays=[0.5, 1.5] | 前三链全失效的兜底 | **0.5s / 1.5s** |

微信类 App 启动初期对链 1/2/3 全部不可见 → 最早命中点是 fallback 第一档 **0.5s** → 窗口在错误屏可见 0.5~1.5s 才被搬走。「部分应用」= 命中 H1 的 App + 命中 H2 的 App。搬动后的恢复链路（stabilityCheck 100ms 重试 + 多档 fallback + 150ms 位置验证）健全，问题纯粹在「窗口出现 → 检测命中」的延迟。

macOS 跨进程固有限制：窗口创建即渲染首帧，无法在其出现前拦截，只能缩短可见时长；H2 的 move-only 可见性为 App 不支持 AX hidden 的固有限制，无法跨进程消除。

## Fix
- 改动文件：SwallowScreen/WindowMover.swift（1 处）
- 一句话改了什么：`handleAppLaunch` 中 `scheduleAXFallbackMove` 调用点 delays `[0.5, 1.5]` → `[0.25, 0.5, 1.5]`，插入 0.25s 早档
- 效果：微信类 App 的「错误屏可见期」从 ≥0.5s 压缩到 ~0.25s（AX 属性就绪早于 0.25s 的 App 直接命中早档；就绪更晚的仍由 0.5s/1.5s 档兜住，不回退）
- 安全性：0.25s 档空转 = 一次 AX 属性查询，成本可忽略；命中后 `isBoundsInTargetFrame` 守卫使后续档位自动跳过（L788 附近既有逻辑），无新竞态
- 用户决策：F2（启动期前 200ms CG 轮询恢复 16ms，L62-63 注释记录的 D2 设计）经评估收益边际（普通 App 33~66ms 本已接近无感），**用户明确只做 F1**

## Verification
> 用 V- 前缀（verification log）而非 AC-，避免与 spec acceptance criteria 混淆。

- V-1: 构建验证 ✓ —— Xcode xcodebuild `-scheme SwallowScreen build` → **BUILD SUCCEEDED**（swift build 因 CommandLineTools 缺 SwiftData 宏插件预先失败，与本次修改无关，同 V-历史结论）
- V-2: 修复前手动复现协议 → 现象存在（用户报告稳定复现）
- V-3: 修复后重启微信类 App → 窗口在错误屏可见期应明显缩短（~0.25s 内被搬走）（**待用户验证**）

## Regression test
- 无测试基建，回归保障 = 本文档 Reproduction 手动协议（delays 为纯数据改动，行为分支无新增）

## Pattern analysis
| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| `grep scheduleAXFallbackMove SwallowScreen/` | 定义 L766 + 调用 L760（唯一调用点） | 否——单调用点，改一处全局生效；无其他延迟兜底路径残留旧时序 |

## Open questions / Follow-ups
- F2（启动期高频 CG 轮询）已评估、用户决策不做；若未来仍感可见期偏长可重启此项
- H2（move-only 可见搬动）为固有限制，如需彻底消除需被管理 App 侧支持 AX hidden，暂无跨进程手段
