# Bug: 自更新脚本 rm 后 cp 无回滚，cp 失败导致 /Applications 中应用丢失

> Status: FIXED
> Mode: (default)
> Severity: functional（数据丢失风险）
> Author: user
> Last updated: 2026-10-18

## Symptom
DMG/ZIP 自更新脚本先 `rm -rf` 旧版再 `cp -R` 新版。cp 失败（磁盘满/权限/源异常）时 /Applications 中应用已被删除且无任何回滚手段，用户只能重新下载安装包。

## Expected
替换流程的任何一步失败，旧版本应用必须完好保留；新版本就位后再移除旧版本。

## Reproduction
沙箱脚本测试（/tmp/swallowscreen_replace_test.sh，已跑完删除）：把替换段逻辑抽到临时目录沙箱执行。

- 场景1 成功替换：旧 app → cp 成功 → 原子替换 → 新版就位、.new/.old 清理
- 场景2 cp 失败（源缺失模拟磁盘满）：**旧版内容完好保留**、.new 已清理、不执行替换（真实脚本中为 exit 1 中止）
- 场景3 首次安装（/Applications 无旧版）：mv 缺源报错被 `2>/dev/null` 吞掉不阻断，新版正常就位
- 复现稳定性: 3/3 PASS

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | `rm -rf` → `cp -R` 顺序 + cp 无退出码检查 + 无 set -e，任一失败点均导致应用丢失且脚本继续跑 `open` 不存在的路径 | confirmed (root cause) | RelaunchManager.swift 修复前 DMG L118-120 / ZIP L155-157；脚本无任何错误检查 |
| H2 | cp -R 直接覆盖已存在目录可行（无需 rm） | eliminated | `cp -R src dst` 当 dst 为已存在目录时把 src 复制为 dst 的**子项**（dst/SwallowScreen.app），产生嵌套损坏——这就是原脚本必须先 rm 的原因；故正确解法是 cp 到不存在的临时名再 rename |

## Root cause
替换顺序缺陷：先破坏性删除唯一副本（rm -rf），再执行可失败操作（cp -R），且失败不可检测（无 `$?` 检查 / 无 set -e）。cp 失败后磁盘上无任何可用副本。

## Fix
- 改动文件: `SwallowScreen/RelaunchManager.swift:118-131`（makeDMGScript）与 `:165-179`（makeZipScript）
- 一句话改了什么: 「rm 后 cp」→「cp 到同卷临时名 `.new` → 失败即退出（清 .new、卸载 DMG/清临时目录）→ 成功后 mv 原子替换（旧版暂存 `.old`，就位后删除）」
- 代码 diff 摘要（两处脚本同构）:

```bash
# 复制失败 → 清理残留 + exit 1（DMG 版还先 detach），旧版本从未被触碰
cp -R "$APP_PATH" "<target>.new"
if [ $? -ne 0 ]; then ... exit 1; fi
# 同卷 rename 原子替换：两步 mv 都是瞬时原子操作，中间态旧版在 .old 仍可手动恢复
mv "<target>" "<target>.old" 2>/dev/null
mv "<target>.new" "<target>"
rm -rf "<target>.old"
```

- 安全性自检:
  - 开头清理历史残留 `.new`/`.old`（上次失败遗留）
  - `.new`/`.old` 均与目标同卷同目录，mv 为纯 rename（瞬时、原子），不存在跨卷拷贝窗口
  - 最坏情况（步骤间被杀）：旧版在 `.old` 可手动恢复，优于原方案「什么都不剩」

## Verification
- V-1: 沙箱测试 3 场景（成功替换 / cp 失败旧版保留 / 首次安装）3/3 PASS ✓
- V-2: xcodebuild 构建（#1+#2 全部修改后重跑）** BUILD SUCCEEDED ** ✓
- V-3: 真实自更新链路验证（待用户，需发布新版本后走一次 DMG 更新）

## Regression test
沙箱测试为一次性脚本（/tmp，未入仓）——替换段逻辑随 Swift 模板字符串存在，无独立可测单元；防回归依赖脚本注释中的 FIX-无回滚 标记 + V-3 真实更新演练。

## Pattern analysis
| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| `grep -n "rm -rf"` RelaunchManager.swift | 8 处 | 否——其余 5 处均作用于 `.new`/`.old` 临时副本或 `$TMP_DIR`（失败也无损失），DMG 中「未找到 .app」分支的 detach 前无 rm 操作；无同模式破坏性删除 |

## Open questions / Follow-ups
- makeDMGScript 的挂载点解析 `tail -1 | awk '{print $NF}'` 对 hdiutil 多行输出较脆弱（审查报告 P3 #14 之外的观察项），未在本次修复范围
