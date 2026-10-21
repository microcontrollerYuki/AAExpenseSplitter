# AAExpenseSplitter（AA记账）

离线优先的 Android 个人记账与双人 AA 工具。当前已支持六币种记账、两级分类、跨币种转账及手续费、联网 / 手动参考汇率、本地图片 OCR 辅助录入、加密 AA 文件交换；最终目标是无障碍识屏自动记账，该能力尚未实现。

截至 **2026-10-21**，代码版本 `0.2.0+5000`、数据库 schema **6**。当前优先完善普通记账与报表，AA 增强和无障碍功能延后。

| 入口 | 内容 |
|---|---|
| [项目概览与文档导航](Docs/README.md) | 当前功能、限制、文档职责 |
| [开发进度](Docs/开发进度.md) | 阶段进度、最新交付、下一步 |
| [总 TODO](Docs/TODO-无障碍自动记账.md) | 65 个任务的唯一状态清单及验收规则 |
| [测试说明](Docs/测试说明.md) | 回归命令、测试分层、雷电验收流程 |
| [AI 交接说明](Docs/AI交接说明.md) | 接手检查、当前边界、下一任务、逐点审查 / 测试 / 设备验收 / 提交推送要求 |

最近完成 **R-04 收入饼图与分类排行**：图表页可切换收入 / 支出维度，共用同一选集与折算快照的饼图与分类排行，内部分类收入排除；此前已交付明细页自定义日期范围（首末日包含的跨月 / 跨年筛选）、年报粒度切换与 12 个月趋势、明细 / 图表默认折合 CNY 总收支与独立原币切换、共享汇率与转账预填（规则见 [汇率服务](Docs/汇率服务.md)）。下一步依次为：**R-05 统计明细 → R-06 筛选组合完整性 → R-07 / R-08 月日历**。

## 开发与验证

Flutter / Dart、Riverpod、Drift / SQLite；Android 为当前验收平台，iOS 未验收。金额采用对应币种的整数最小单位；JPY 不使用小数。普通外币账单留在本机，现有 AA 同步仅支持 CNY。

在 `app` 目录使用已配置的 Flutter SDK：

```powershell
flutter pub get
flutter test --no-pub --reporter expanded --timeout 20s
flutter analyze --no-pub
flutter build apk --debug --no-pub
```

此电脑 SDK 位于 `D:\Dev`，开发缓存及验证产物集中在 `D:\Projects\AAExpenseSplitter\.local-dev`。当前检出目录可能是 Codex worktree，请勿用固定 `cd` 路径切到另一份代码。本机 D 盘启动脚本的用法见 [测试说明](Docs/测试说明.md)。同一工程的 Flutter / Dart 命令按顺序执行。

每个功能小点都须重新审查、跑专项与短回归、覆盖安装两台雷电并实际操作，通过后提交和推送。设备数据库、同步文件、截图和日志不入仓库。正式签名、真机和发布验收仍在 P7 计划内。

## 代码位置

- [app/lib](app/lib)：页面、组件、金额 / 报表工具、数据库、OCR 和 AA 同步。
- [app/test](app/test)：数据层、迁移、业务、页面与组件回归。
- [独立交易测试 App](tools/transaction_fixture/README.md)：供未来识屏验证的合成场景，不能替代真实支付平台验收。

早期 README 与逐轮记录保存在 [历史档案](Docs/archive/README.md)。历史描述中的“下一版本”和勾选状态只代表当时记录。
