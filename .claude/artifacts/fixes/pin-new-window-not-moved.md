# Bug: 已运行应用新开的窗口没有被搬到 pinToScreen 固定屏幕，手动拖动后才会回弹

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-10-18

## Symptom
部分应用已设置「固定显示屏幕」（pinToScreen），应用已在运行且主窗口已在固定屏幕上；此时应用再打开**新窗口**（如 Cmd+N、微信新聊天窗），新窗口不会出现在固定屏幕上，停留在当前屏幕。手动拖动新窗口一次后，松手时窗口才会被自动搬回固定屏幕。

## Expected
已设置 pinToScreen 的应用，其**所有**窗口（含运行期间新开的窗口）都应立即出现在固定屏幕上，无需手动拖动触发。

## Reproduction
无自动化测试基建（Package.swift 仅有 executableTarget，无 testTarget；AX 窗口行为依赖真实 macOS 窗口系统，无法单测）。经用户确认采用**手动复现协议 + 构建验证**替代 failing test（dev-fix Step 2/7 的 red→green→red 以「修复前手动复现失败 / 修复后手动验证通过 + swift build 通过」等价执行）。

- 步骤（协议）:
  1. SwallowScreen 运行中，为微信（或 Finder）配置 pinToScreen 到非当前主屏的某个屏幕
  2. 确认应用主窗口已在固定屏幕上
  3. 在应用内触发新窗口：微信 Cmd+N 新聊天 / Finder Cmd+N 新 Finder 窗口
  4. 观察：新窗口停留在当前屏幕（bug 现象）；手动拖动一次后松手，窗口被搬回固定屏幕（确认命中 pinToScreen 执行路径）
- 复现稳定性:用户报告稳定复现（「部分应用」= 多窗口应用，新窗口小于主窗口时 100% 复现）

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | pinToScreen 执行体系只跟踪每个应用的一个「主窗口」，新开窗口完全不在监控范围：100ms 轮询每 pid 只查面积最大的有标题窗口；长期 pinObserver 只订阅 kAXMovedNotification（窗口创建不触发）；kAXWindowCreatedNotification 仅在应用启动路径一次性注册、首个窗口处理后即移除 | confirmed (root cause) | 静态代码链路：WindowMover.swift L315-316（一次性清理）、L352-356（pinObserver 仅 moved）、L901-943 fetchAllOnScreenMainWindows 每 pid 单窗口、L1586-1703 轮询单窗口检查。与新窗口不搬、拖动（触发 moved 事件）后回弹的症状完全吻合 |
| H2 | 屏幕配置变化 / 缓存失效导致 pinTargetCache 过期误判 | eliminated | 主窗口已在固定屏幕（轮询每 100ms 检查通过），说明缓存与映射正常；若缓存失效主窗口也会被误判搬动，与「只有新窗口不搬」矛盾 |
| H3 | 新窗口在目标屏但被隐藏/最小化未显示 | eliminated | 症状是新窗口出现在**当前屏幕**且拖动后能回弹，说明窗口正常可见，只是位置不对 |

### 反向追溯（H1 confirmed 后）
失败观察点：新窗口停在当前屏幕。沿 pinToScreen 三条执行路径反向追溯：
1. 轮询路径 → `fetchAllOnScreenMainWindows()` 每 pid 只返回**一个**最优窗口 bounds → 新窗口（面积小于主窗口）不被检查 —— 首次引入点
2. pinObserver 路径 → 只订阅 `kAXMovedNotification`，窗口创建事件不到达 —— 首次引入点
3. 启动路径 → `setupAXObserver`（kAXWindowCreatedNotification）在 `handleAppLaunch` 后处理首个窗口即 `removeAXObserver(for: pid)`（L315-316）—— 设计如此（只服务启动场景），覆盖不到运行期新窗口

三条路径均未覆盖「运行期新窗口创建」→ bad state（新窗口位置不受控）由**路径设计缺口**首次引入。

## Root cause
pinToScreen 的长期 AX 监听（`setupPinObserver`）只为 pinned 应用订阅了 `kAXMovedNotification`；窗口**创建**事件（`kAXWindowCreatedNotification`）只在应用启动路径（`setupAXObserver`）注册且为一次性（首个窗口处理后即移除）。同时 100ms 轮询 `checkAndEnforcePinnedWindows` 每个应用只检查一个「主窗口」（面积最大的有标题窗口）。因此已运行应用新开的窗口（多窗口应用中面积小于主窗口的聊天窗/Finder 新窗）不在任何执行路径的监控范围内，直到用户手动拖动触发 `kAXMovedNotification` → `handlePinWindowMoved` → 松手后 `performPinCheck` 才被搬回固定屏幕。

「部分应用」现象解释：单窗口应用或新窗口成为最大标题窗口的应用能被轮询覆盖正常工作；只有多窗口应用的新窗口（小于主窗口）暴露此缺口。

## Fix
- 改动文件：SwallowScreen/WindowMover.swift（4 处，全部在 pinToScreen observer 路径）
- 一句话改了什么：pinObserver 追加订阅 kAXWindowCreatedNotification，创建事件携带窗口 element 分发到新处理器，新窗口经 moveWindowToTargetScreen 立即搬到固定屏幕
- 代码 diff 摘要（关键行）:
  1. `setupPinObserver`：追加 `AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification, nil)`（失败仅记日志，不影响 moved 监听）
  2. `pinObserverCallback`：moved → `handlePinWindowMoved(pid:)`；created → `handlePinWindowCreated(pid:element:)`
  3. 新增 `handlePinWindowCreated(pid:element:)`：guard `!isPerformingInitialMove` → guard `pinTargetCache[pid]` → AX 读 position/size（可读 = 存活就绪）→ 尺寸 ≥50 过滤瞬时/辅助窗口 → `isBoundsInTargetFrame` 已在目标屏则跳过 → 独立 windowID `"\(pid)-created"` 防循环（movingWindows/lastMovedWindows）→ `moveWindowToTargetScreen`（内部 hideMoveUnhide + 冷却 + 500ms 延迟验证）
  4. `removePinObserver`：同步 `AXObserverRemoveNotification(kAXWindowCreatedNotification)`（deinit/stopMonitoring 直接 removeAll 释放 observer，无需改）

## Regression（回归修复，2026-10-18）
- **症状**：重启 SwallowScreen 后，所有固定屏应用的窗口停在错误屏幕，等待不恢复（用户确认：操作序列 = 重启 SwallowScreen 本身；表现 = 在错误的屏幕；范围 = 所有固定屏应用；症状 = 一直不恢复）
- **根因**（AX 快照 + 启动搬动竞态）：
  1. SwallowScreen 启动后首次 `checkAndEnforcePinnedWindows` 指纹必变（lastAppsFingerprint 初始 0）→ `refreshPinObservers` 为所有运行中 pinned app 注册 created 订阅
  2. **AX 快照行为**（yabai/Hammerspoon 社区已知）：应用级订阅 kAXWindowCreatedNotification 后，应用立即为**所有已存在窗口**补发 created 通知
  3. 此时启动路径的 `startStabilityCheck`（100ms × 最长 2s 反复 hideMoveUnhide）/ `verifyAndRecenterWindow`（500ms 延迟验证）仍在运行，`isPerformingInitialMove` 已置 false → `handlePinWindowCreated` 不被启动期 guard 拦截 → 对所有不在目标屏的窗口强制搬动，多层搬动互相覆盖 → 窗口散落错误屏幕
  4. **「一直不恢复」解释**：周期纠正（`checkWindowPosition`）只覆盖每 pid 的主窗口（`fetchAllOnScreenMainWindows` 用 `.optionOnScreenOnly` 且仅取最大窗口），快照竞态散落的辅窗口/跨 Space 窗口不在覆盖内
- **回归修复**（快照截止窗口，4 处最小修改）：
  1. 新增属性 `createdSnapshotCutoff: [pid_t: Date]`
  2. `setupPinObserver`：created 订阅**成功**后记录 `createdSnapshotCutoff[pid] = Date()+1.0s`
  3. `handlePinWindowCreated` 入口（isPerformingInitialMove guard 之后）：截止窗口内直接 return，过期惰性清理（快照通知在订阅后毫秒级到达，1s 窗口足够；1s 后的真·新窗口通知正常处理，保留原修复功能）
  4. `removePinObserver`：同步清理 `createdSnapshotCutoff[pid]`
- **回归修复验证**：Xcode xcodebuild **BUILD SUCCEEDED**；待用户按下方三场景手动验证

## Verification
> 用 V- 前缀（verification log）而非 AC-，避免与 spec acceptance criteria 混淆。

- V-1: 构建验证 ✓ —— `/Applications/Xcode.app/.../xcodebuild -scheme SwallowScreen build` → **BUILD SUCCEEDED**。注：`swift build` 因 CommandLineTools 缺 SwiftData 宏插件预先失败（SettingsView.swift `@Query` 宏错误）；经 `git stash` 对比验证：无本次修改时同样失败（210 errors），证明与本次修改无关
- V-2: 修复前手动复现协议 → bug 现象存在（用户报告稳定复现，协议见 Reproduction 段）
- V-3: 修复后手动复现协议 → 新窗口立即自动搬到固定屏幕，无需拖动（**待用户验证**）
- V-4: 拖动回弹（kAXMovedNotification 原路径）回归验证不受影响（**待用户验证**）
- V-5: 回归修复后构建验证 ✓ —— Xcode xcodebuild **BUILD SUCCEEDED**
- V-6: 回归场景验证——重启 SwallowScreen 后所有固定屏应用窗口应正确停在固定屏幕（**待用户验证**）

## Regression test
- 无测试基建，回归保障 = 本文档 Reproduction 手动协议（未来若引入 testTarget，可将 `handlePinWindowCreated` 的位置判定逻辑抽为纯函数后单测）

## Pattern analysis
| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| `grep kAXWindowCreatedNotification SwallowScreen/` | 仅 setupAXObserver（启动路径） | 是——启动路径一次性设计是有意的，但 pinToScreen 场景缺失长期创建监听，本次修复即补齐 |

## Open questions / Follow-ups
- targetScreen（非 pinToScreen）应用的新窗口是否也需要搬动？当前 `setupPinObserver` 仅服务 pinToScreen 应用，本次修复不动 targetScreen 语义（避免需求外改动）
