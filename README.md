# AAExpenseSplitter（AA记账）

离线优先的 Android 个人记账与双人 AA 工具。当前已支持六币种记账、两级分类、跨币种转账及手续费、联网 / 手动参考汇率、本地图片 OCR 辅助录入、加密 AA 文件交换；最终目标是无障碍识屏自动记账，该能力尚未实现。

截至 **2026-10-23**，代码版本 `0.2.0+5000`、数据库 schema **6**。当前优先完善普通记账与报表，AA 增强和无障碍功能延后。

| 入口 | 内容 |
|---|---|
| [项目概览与文档导航](Docs/README.md) | 当前功能、限制、文档职责 |
| [开发进度](Docs/开发进度.md) | 阶段进度、最新交付、下一步 |
| [总 TODO](Docs/TODO-无障碍自动记账.md) | 65 个任务的唯一状态清单及验收规则 |
| [测试说明](Docs/测试说明.md) | 回归命令、测试分层、雷电验收流程 |
| [AI 交接说明](Docs/AI交接说明.md) | 接手检查、当前边界、下一任务、逐点审查 / 测试 / 设备验收 / 提交推送要求 |

最近完成 **R-06 报表组合完整性**：图表支持月 / 年 / 自定义范围、收入 / 支出及总览 / 原币组合；分类、窗口、趋势与精确集合保持金额守恒，图表重选范围不切换明细模式。专项 10/10、全量 1039/1039、双雷电真实行开窗与编辑刷新通过，原完整六表和汇率已恢复。代码已推送并核对；总清单 36 完成 / 29 待办，下一项 **R-07 月日历聚合 → R-08 日历界面**。此前能力见 [项目概览](Docs/README.md) 与 [汇率服务](Docs/汇率服务.md)。

## 开发与验证

Flutter / Dart、Riverpod、Drift / SQLite；Android 为当前验收平台，iOS 未验收。金额采用对应币种的整数最小单位；JPY 不使用小数。普通外币账单留在本机，现有 AA 同步仅支持 CNY。

在 `app` 目录使用已配置的 Flutter SDK：

```powershell
flutter pub get
flutter test --no-pub --reporter expanded --timeout 20s
flutter analyze --no-pub
Push-Location android
try { .\gradlew.bat assembleDebug } finally { Pop-Location }
```

此电脑 SDK 位于 `D:\Dev`，开发缓存及验证产物集中在 `D:\Projects\AAExpenseSplitter\.local-dev`。本机主工作区为 `D:\Projects\AAExpenseSplitter`，当前分支 `Glm5.3F`；不要切到 C 盘旧 Codex worktree。测试 / 分析使用 `aa-dev-glm.ps1`，构建使用 `gradlew assembleDebug`，以保证 QA 所需的可调试包；本机 Flutter build 包装曾固定生成 release，不能用它代替 debug 验收。配置见 [AI 交接说明](Docs/AI交接说明.md#本机环境与常用命令) 与 [测试说明](Docs/测试说明.md)。同一工程的 Flutter / Dart 命令按顺序执行。

每个功能小点都须重新审查、跑专项与短回归、覆盖安装两台雷电并实际操作，通过后提交和推送。设备数据库、同步文件、截图和日志不入仓库。正式签名、真机和发布验收仍在 P7 计划内。当前范围报表的趋势使用固定宽度月份轴，超过 12 个月时标签与柱形可能拥挤、跨年月份标签不含年份；这是可读性限制，全部月份与金额仍参与聚合，不将其记作丢额。

## 代码位置

- [app/lib](app/lib)：页面、组件、金额 / 报表工具、数据库、OCR 和 AA 同步。
- [app/test](app/test)：数据层、迁移、业务、页面与组件回归。
- [独立交易测试 App](tools/transaction_fixture/README.md)：供未来识屏验证的合成场景，不能替代真实支付平台验收。

早期 README 与逐轮记录保存在 [历史档案](Docs/archive/README.md)。历史描述中的“下一版本”和勾选状态只代表当时记录。
