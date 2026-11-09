# Context

## Glossary

| Term | Meaning | Notes |
|---|---|---|
| 检测链 | 检测目标应用窗口出现并触发搬动的机制 | 现状四条：AXObserver 事件 / CGWindowList 轮询 / AX 轮询 / fallback 定时，全部为「事后检测」 |
| 可见期 | 窗口在错误屏幕的可见时长 | 闪动的度量；目标「人眼不可感知」= <100ms |
| 根治主链 | 首帧合成前把窗口搬到目标屏的机制 | CGS 私有 API（CGSMoveWindow）+ SLS 事件（SpaceWindowCreated=1325），绕过目标应用 AX 树就绪延迟 |
| AX 兜底链 | 根治链失效时保底的搬动机制 | 现有四条链 + 全路径 hidden 化（先隐藏→搬→显示，失败回退 move-only） |
| 搬动路径 | 触发搬动的场景 | 启动搬窗 / 运行中新开窗口 / 拖动回弹 / 全屏退出 / 定期纠偏；本方案全部路径统一 hidden 化 |
| move-only | 不支持 AX hidden 属性的窗口直接移动 | 搬动过程可见，固有限制，hidden 失败的兜底 |
