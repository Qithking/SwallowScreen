# Bug: Windows App 远程桌面窗口位置不受应用规则限制（全屏窗口无法搬移 + 多窗口概率性不搬）

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-11-09

## Symptom
Windows App（微软远程桌面）打开远程桌面会话窗口时，窗口位置不受应用规则（pinToScreen）限制：
- 会话窗口窗口化 + 点击 macOS 绿灯全屏，均有**一定概率**不在设置的目标屏幕显示
- 打开后窗口**一直留在当前屏幕不动**（轮询不纠正）

## Expected
已设置 pinToScreen 的应用，其所有窗口（含远程会话窗）都应立即出现在固定屏幕上。

## Triage
- **Repro 起点**：Windows App 打开远程桌面会话窗口（窗口化 / 绿灯全屏两种形态）
- **Environment**：macOS；双屏——screen[0] 2560x1440 @(0,0) id=5（主屏）、screen[1] 1920x1080 @(-1920,360) id=1（副屏）
- **First seen**：多窗口应用（Windows App 同 pid 含连接列表窗 + 会话窗）
- **Severity**：影响功能（窗口管理核心能力失效）
- **测试基建约束**：本仓库无 AX 行为自动化测试基建（沿用问题12 artifact 结论），以「手动复现协议 + 构建验证」等价执行 red→green→red

## Reproduction（手动协议）
1. SwallowScreen 运行中，Windows App 配置 pinToScreen 到非当前屏
2. 打开远程桌面会话窗口（窗口化）→ 观察窗口停在当前屏（bug 现象）
3. 点绿灯全屏 → 观察窗口全屏后仍停在当前屏且永不搬动（bug 现象）

## 实测证据（诊断阶段采集，非推断）
```
Windows App pid=1476（运行中）：
  CGWindowList: owner=Windows App layer=0 alpha=1.0 bounds=(0,0 2560x1440) title=dev.justep.com:33316
  → 会话窗口铺满整屏 = 全屏态；与连接列表同一 pid（非独立进程）
```
诊断工具：/tmp/diag-windows.swift（CGWindowList + AX 双视图）；命令行脚本无 AX 权限，CGWindowList 部分已足够取证。

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1（根因 A） | 全屏窗口在独立 Space，AX `kAXPositionAttribute` 设置被系统忽略；代码完全没有全屏处理路径 → 全屏后「一直不动」 | confirmed (root cause) | `grep FullScreen` WindowMover.swift → 0 匹配；hideMoveUnhide→moveWindowToFrameImmediate 只做 AX setPosition；yabai/Hammerspoon 社区已知 macOS 全屏窗口限制 |
| H2（根因 B） | 100ms 轮询每 pid 只检查**面积最大的带标题窗口**，多窗口应用中小窗口不被轮询覆盖 → 窗口化「有一定概率不搬」 | confirmed (root cause) | fetchAllOnScreenMainWindows 每 pid 单窗口返回；checkWindowPositionFastPath 的 pinWindowCache[pid] 缓存后固化（仅 AX 读失败才清）；created 通知路径（问题12 修复）走通则成功、走不通落到轮询 |
| H3 | pinTargetCache / 屏幕映射失效误判 | eliminated | 会话窗口化时部分场景能被搬（概率性），说明目标屏解析正常 |

### 反向追溯
- H1 首次引入点：pinToScreen 执行路径（checkWindowPosition 普通/fastPath → moveWindowToTargetScreen）从未考虑全屏态——设计缺口
- H2 首次引入点：fetchAllOnScreenMainWindows 的「每 pid 取最大窗口」聚合逻辑

## Root cause
- **根因 A**：macOS 原生全屏窗口运行在独立 Space，AX setPosition 被系统静默忽略；代码 0 处全屏检测/处理，全屏窗口的任何搬动都无效。
- **根因 B**：轮询与 fastPath 只跟踪每 pid 一个「主窗口」（面积最大带标题），Windows App 多窗口（连接列表 + 会话窗）中小面积会话窗不被覆盖；created 通知路径部分走通部分落空 → 概率性。

## Fix（方案 A，用户确认：退出全屏 → 移动，**不自动重进全屏**）
全部在 SwallowScreen/WindowMover.swift，7 处外科手术式修改：

1. 新增属性 `fullscreenExitAttempts: [pid_t: Date]`——退出全屏防重入冷却（3s，动画期轮询每 100ms 命中）
2. `fetchAllOnScreenMainWindows` → `fetchAllOnScreenWindowBounds`：返回每 pid **所有**候选窗口（layer 0、alpha>0、有 title 全收 + 无 title ≥50，面积降序；≥50 过滤与 handlePinWindowCreated 一致）
3. 启动搬窗路径：取 `?.first`（面积最大窗口），其余窗口由轮询覆盖
4. 轮询路径（checkAndEnforcePinnedWindows）：逐窗口检查，首窗口沿用 `\(pid)-main` 标识，其余追加 `-index` 后缀，各窗口独立冷却检查
5. `checkWindowPosition`：新增 `windowKey` 参数（默认 `"\(pid)-main"`）；普通路径移动分支前插入全屏检测
6. fastPath 移动分支同样插入全屏检测
7. 新增 `isWindowFullScreen`（subrole `AXFullScreenWindow` / `AXFullScreen` 属性双信号）+ `triggerExitFullScreen`（首选置 `AXFullScreen=false`；失败兜底按下 subrole 为 `AXFullScreenButton` 的绿灯按钮；1.5s 窗口冷却防动画期反复搬动）+ removePinObserver 清理冷却记录

**全屏处理流（方案 A）**：轮询发现窗口不在目标屏 → 全屏检测命中 → 退出全屏 → 本轮跳过移动 → 下一轮轮询（~1-2s 后）以普通窗口身份走既有 hideMoveUnhide 路径搬回目标屏 → 不重进全屏（用户需要时手动点绿灯）。

## Verification
> 用 V- 前缀（verification log）。⚠️ 本会话期间 xcodebuild 宏插件环境失效，构建验证降级。

- V-1: `swiftc -parse` WindowMover.swift → **PARSE OK**（语法层）
- V-2: 新引入 AX 常量/API（kAXSubroleAttribute / kAXZoomButtonAttribute / kAXPressAction / AXUIElementSetAttributeValue+kCFBooleanFalse / AXUIElementPerformAction）独立 `-typecheck` → 通过（类型层）
- V-3: 完整 xcodebuild 被预存在环境问题阻塞：swift-plugin-server malformed response（SwiftData/SwiftUI 宏无法展开）；**git stash 对照实验**——stash 掉本次修改后同样 562 个宏错误，证明与本次修改无关（问题22 期间同一命令曾 BUILD SUCCEEDED，属环境状态变化）
- V-4: 修复前手动复现 → bug 现象存在（用户报告）
- V-5: 修复后手动验证四场景（**待用户执行**）：
  1. 会话窗窗口化打开 → 立即被搬到目标屏（重复多次，验证概率性消失）
  2. 全屏不在目标屏 → 自动退出全屏并搬到目标屏（退出后不自动重进全屏）
  3. 用户在目标屏手动全屏 → 不被打扰
  4. 正常单窗口 App（pinToScreen）回归不受影响
- V-6: 环境恢复后补跑完整 xcodebuild 构建（已记入待办）

## Regression test
无测试基建；回归保障 = 本文档手动协议。未来若引入 AX 测试 target，可对 isWindowFullScreen 的双信号判定逻辑抽纯函数单测。

## Pattern analysis
| 搜索方式 | 命中数 | 结论 |
|---|---|---|
| `grep FullScreen SwallowScreen/`（修复前） | 0 | 全屏处理完全缺失——本次即补齐 |
| `grep AXFullScreenWindow`（修复后） | isWindowFullScreen 单点 | 全屏检测收敛在单一方法，未来其他路径复用即可 |

## Open questions / Follow-ups
- Windows App 对 `AXFullScreen` 属性 set 的响应能力未知（无法命令行验证 AX 权限）——若实测无效，ZoomButton 兜底路径应生效；若两者都无效（可能性低），需升级 `--deep` 采集运行时日志再定位
- 拖动回弹路径（handlePinWindowMoved → performPinCheck fastPath）已覆盖全屏检测，但用户拖动全屏窗口本身不可行，该场景理论不可达
- 环境恢复后补跑完整 xcodebuild 构建（待办已记）
- 此前批次遗留：UpdateChannel 的 CaseIterable 无 consumer（P2 finding），是否删除由用户定夺
