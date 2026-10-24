# AI 开发交接说明

交接更新：**2026-10-24**（保留 R-06 历史快照）。面向接手本项目的 AI 开发代理。先核对实际仓库与最新文档，再动手；本文是交接快照，后续任务勾选以 [总 TODO](TODO-无障碍自动记账.md) 为准，验证结果以 [开发进度](开发进度.md) 和 [测试说明](测试说明.md) 为准。不要把历史档案里的“下一项”当成当前任务。

## 用户目标与工作要求

项目是离线优先的 Android 个人记账与双人 AA 工具，最终目标为通过无障碍读取受支持支付 App 的交易屏幕，先生成待核对候选，再按用户规则自动记账。

**用户已于2026-10-24要求依据钱迹逆向迁移阶段计划继续实施。近期顺序为 R-07 → R-08 → D-01 → P2-02 → P1-05 → AA-01～04；无障碍及其余P2～P7后置。一次只推进一个可独立验收的小点，不把多个未验证功能合在一起提交。每完成一个小点，必须重新审查代码、运行新功能专项与回归测试、覆盖安装两台既有雷电并实际操作，确认无问题后提交并推送；没有通过的门槛不得记作已完成。**

与用户用中文沟通。明确说明交付行为、测试数量 / 耗时、设备结果、限制和提交，不只给计划或口头声称测试通过。长操作期间持续提供简短进度。

最终产品仍须满足 [总 TODO 的最终验收标准](TODO-无障碍自动记账.md#最终验收标准)：真实受支持平台正确识别完成交易的金额 / 方向 / 时间 / 账户 / 分类，不确定或未完成交易待核对；用户启用后界面关闭仍能后台入账，暂停 / 撤销权限后停止；重复事件、节点 / OCR 双命中、重启 / 升级不重记，不误合并真实同额两笔；旧账、余额、AA 和结算保持正确，识别记录可追溯、修改与撤销。系统强制停止后的恢复限制须如实说明。每个阶段按证据交付，不能用雷电合成场景替代真机 / 真实平台验收。

## 当前可靠基线

| 项目 | 本次交接状态 |
|---|---|
| 仓库 / 分支 | `https://github.com/microcontrollerYuki/AAExpenseSplitter.git` / `Glm5.3F`（已合并 `codex/stabilize-aa` 与远端 main） |
| 最近已交付功能 / 既有 WIP | R-08 `c04c11a360f0cbd3d07fb24198386ae5589c56d9` 已推送`origin/Glm5.3F`并核对远端等于HEAD；R-07 `353ec1a`、R-06 `006b2c7`及原WIP `053b224`/交接`f5822f3`均保留 |
| 版本 / 数据库 | `app/pubspec.yaml` 为 `0.2.0+5000`；Drift / SQLite schema 6 |
| 总任务 | 70个唯一编号，38完成 / 32待办；原65项保留，新增D-01与AA-01～04仍待办；R阶段10 / 10，R-08已交付 |
| 最近专项 / 全量 | R-08新增15条，相关九文件82/82（runner7秒/命令10.5秒）；全量1067/1067（runner68秒/命令71.6秒）；独立复审无未决P1/P2，双机 / 完整数据 / 远端门槛通过；推送后15/15短回归通过 |
| 分析 | R-08为0 error、27条原有warning/info（runner3.3秒/命令4.8秒）；无新增，不能宣称存量清零 |
| 当前构建 / 设备 | R-08 gradlew assembleDebug25.8秒，SHA-256 `CCAA32D687A173844C91D2108734C8E54466F9592F578E5AAE9018DDAC3EEA49`；两机31天金额、编辑 / 日期移动 / 删除及原功能冒烟通过，完整六表含原FX与基线相同、QA0 / FATAL0；C-13断网遗留不变 |
| 当前下一项 | **D-01完整备份恢复（未实现）**，再P2-02、P1-05和AA-01～04；不重复已交付R-08 |

R-08已完成全部门槛并核对远端，本轮仅新增R-08勾选后为38完成/32待办；R-07交付及五个新增待办登记历史保留。文档不写入自身提交号，接手仍核对git status/log；原未跟踪TestPictures/data/保留，不入提交。

已交付：手动收支、本人转账、六币种账户及实际双额、转账内手续费、两级分类 / 宫格选择 / 迁移 / 删除转移、手选年月、底部账单详情、原币月统计 / 分类 / 六个月趋势、共享汇率设置、转账汇率预填与手动覆盖、总收支折算模型与全币种选择、明细 / 图表默认折合 CNY 总收支与独立原币切换、年报（粒度切换 / 12 月趋势）、明细页自定义日期范围、图表页收入 / 支出切换与收入分类排行、点击图项查看账单明细窗口、图表范围与组合完整性、图片 OCR 辅助录入、仅 CNY 的双人 AA 与加密文件交换。完整功能 / 限制见 [项目概览](README.md)。

R-07模型与R-08界面、每日三过滤及详情订阅均已交付。AA完整分类路径、无障碍和后台自动入账未交付；预算、CSV、整库备份、回收站仍为占位（备份下一项D-01）。OCR与测试App不能替代无障碍；目标真机、真实支付平台、iOS、正式签名发布未验收。

## 接手时先执行

1. 读取本仓库适用的 `AGENTS.md` 等指令（如果存在），检查 `git status --short`、当前分支、`git log -5 --oneline`、`git remote -v`。保存并理解已有修改，不使用强制 reset、清空工作区、强推或丢弃不属于自己的改动。
2. 按顺序阅读 [项目概览](README.md) → [开发进度](开发进度.md) → [总 TODO](TODO-无障碍自动记账.md) → [测试说明](测试说明.md) → 本 AI 交接说明的 R-06 快照 → 对应专项计划。当前下一步另读 [多币种与报表计划](下一版本计划-多币种与报表.md) 与 [汇率服务](汇率服务.md)。档案和 [早期设计框架](AA记账-功能设计框架.md) 只作历史参考。
3. 确认正在修改哪一份 checkout，SDK / 缓存脚本是否指向它，ADB 对应哪两台原实例。当前必须使用 D 盘主工作区 `D:\Projects\AAExpenseSplitter` 和 `Glm5.3F`；不要切到 C 盘旧 Codex worktree，也不要重建模拟器或清除应用数据。
4. 核对R-08交付、完整数据保护和远端记录，接下来只推进 **D-01完整备份恢复（未实现）**；先固定备份格式 / 密钥策略、WAL一致性、临时库校验和失败回滚的正反例，破坏性恢复只在隔离库 / 设备验证，不覆盖两台既有雷电用户数据。不要重复R-08或合并P2-02 / AA后续任务。

## 任务顺序与下一小点

R-07 / R-08已完成，剩余按 **D-01 → P2-02 → P1-05 → AA-01～04** 逐点交付，保留原编号。P0-01剩余能力探测与其余P2～P7仍待办；搜索/退款等按需独立追加。全部状态与验收要求保留在总TODO，阶段规则见 [钱迹逆向迁移计划](钱迹逆向-基础迁移-AA完善开发计划.md)。

**R-08已交付（2026-10-24）：**

- [月历页面](../app/lib/pages/calendar_stats_page.dart)与[每日明细](../app/lib/pages/calendar_day_sheet.dart)已接入图表切换；`calendarMonthProvider`独立于首页月份，`statsViewProvider`共享图表币种，月历与每日窗口共用同一月度聚合对象。日 / 月金额使用模型逐笔值，不使用`sourceReport`混合原币和。
- 新增15条Widget测试，相关九文件82/82（runner7秒/命令10.5秒）、全量1067/1067（runner68秒/命令71.6秒）；分析0 error、27旧提示（runner3.3秒/命令4.8秒）。修正nullable类型、月末helper滚动和缺率fake，320宽2倍字号及大数通过；独立复审无未决P1/P2。
- 两机31天日/月收支与DB核对一致；QA A金额1→2并日期5→6真实UI保存后，旧日支出0、新日4，删除A后新日2、月支出-2。空日、USD空态 / 总览、年月9月确认 / 8月取消、首页10月独立、每日筛选关闭重开和返回图表状态均通过；竖屏视觉核对通过。
- 原账详情 / 修改取消、新建取消、资产 / AA冒烟通过；每机4精确QA ID经事务内六表schema / count / 全字段guard清理，QA0、完整六表含原FX hash与基线相同，FATAL0，未保存用户原记录。没有网络切换或FX修复，两机force-stop保留最终指纹；原账5554收入22.50 / 支出811.00，5556为0 / 32.50，完整摘要见开发进度。
- 代码`c04c11a360f0cbd3d07fb24198386ae5589c56d9`已推送并核对远端等于HEAD；推送后15/15短回归（runner5秒 / 命令8.2秒）、6产品Dart文件format检查0变化。本轮只新增R-08勾选，70ID / 38完成 / 32待办，下一项D-01未实现。本机证据位于`.local-dev/verification/r08`，原未跟踪`TestPictures/data/`保持不动。

**R-07交付（2026-10-24）：** `calendar_report.dart`提供不可变本月/每日集合、BigInt收支结余及缺率状态，复用R-01筛选与单次折算；13条新增、相关75/75、全量1052/1052，双机原报表/资产/AA回归及含FX完整六表保护通过。仅模型层，设备未操作日历UI；R-08读取模型金额，不能误用`sourceReport`的混合原币和。代码`353ec1a`已推送核对。

**C-13 的实现结果（已完成）：**

- `TransferRatePrefill` 接口（[transfer_rate_prefill.dart](../app/lib/exchange/transfer_rate_prefill.dart)）冻结不可变 `RateQuote` 生成跨币入账候选；弹窗显示方向 / 来源 / 时间 / 手动 / 过期状态，自定义汇率或实际额均为手动输入，采用即显式确认；JPY 只舍入一次。
- 换账户 / 本金 / 币种后旧确认失效；迟到刷新只更新候选显示；历史转账优先回显已保存双额；离线缺率可人工确认；pumpPage 默认惰性注入，页面测试零网络。同签名内快照转旧不自愈是已知显示限制。
- 专项入口 [transfer_rate_prefill_test.dart](../app/test/pages/transfer_rate_prefill_test.dart)；设备级断网操作因雷电 WLAN 与 adbd 联动断开而遗留（R-10 如需断网验证，先解决该环境约束）。
- 同时回归 C-11：手续费按来源币种额外支付，来源改变后须重确认，目标入账确认独立维护；汇率预填不绕过总扣款、关联事务及历史保护（专项已覆盖）。
- 专项覆盖方向 / 反向、JPY / 舍入、手动优先、迟到成功与失败、取消 / 销毁、账户 / 本金改变、缺率 / 过期、历史编辑等，已随 [transfer_rate_prefill_test.dart](../app/test/pages/transfer_rate_prefill_test.dart) 交付；双雷电联网预填、手动率 / 实际额、余额、费用及旧账已通过。

C-13 改动的关键路径：编辑页 `_pickTransferIncoming` / `_TransferIncomingDialog` / `_receivedButtonLabel` / `_ensureTransferRateQuote`，保存路径 `saveTransferWithFee` 未变。既有回归入口为 [转账录入](../app/test/pages/currency_transfer_entry_test.dart)、[手续费录入](../app/test/pages/transfer_fee_entry_test.dart)、[双额数据层](../app/test/data/cross_currency_transfer_test.dart)。

**R-09 的实现结果（已完成）：**

- [report_conversion.dart](../app/lib/utils/report_conversion.dart)：`FrozenCnyQuotes.capture` 一次同步读取冻结全部 →CNY 报价（缺失币对进未纳入清单而非失败）；`CnyConvertedBills.convert` 对 R-01 选集逐笔单次半分远离零舍入，`valueFor` / `sumFor` 供所有分区复用同一逐笔值，缺率 / 未知代码按归一化码合并列出笔数与原币合计，`complete` 标志禁止部分结果自称完整；BigInt 全程可超 int64；只读模型，不改账单、余额或任何表。
- `ReportFilter.allCurrencies` 全币种选择（type 校验委托主构造器）；全币种 `ReportResult` 的原币分类统计有运行时守卫（混合单位结果只作折算输入）。
- 专项入口 [report_conversion_test.dart](../app/test/utils/report_conversion_test.dart)；独立复审七项边界全 PASS，P2 遗留 3 项作为 R-10 设计输入已写入代码文档（全币种结果禁读原始收支和、分区取同一选集实例、脏币种码展示口径）。

**R-10 的实现结果（已完成）：**

- 明细月摘要与图表（饼图 + 趋势）默认经 R-09 折算模型显示折合 CNY；`ReportViewHint` 口径行展示估算标识、来源 / 数据时间、含手动与已过期、未纳入提示；分区只经 `valueFor` / `sumFor` 取值，趋势 6 个月共用一次同步冻结快照。
- `billsViewProvider` / `statsViewProvider` 两页独立视图，切换不改动月份与分类；`CurrencyFilter` 新增「总览 · 折合 CNY」项并恢复菜单定位；`exchangeRateReady/VersionProvider` 提供幂等初始化与刷新重建信号；pumpPage 默认注入固定缓存确定性服务，支持 `rateService` 注入。
- 专项入口 [report_view_test.dart](../app/test/pages/report_view_test.dart)；设备验收通过（总览 / 原币切换、两页独立、金额与设备库一致）。弹出菜单的设备自动化受雷电广告抢占前台影响以重试脚本完成；折算口径行「未纳入」范围为当月（趋势各自缺率未并入口径行），属 R-05 设计输入。

**R-02 的实现结果（已完成）：**

- 图表页新增粒度切换（月 / 年 SegmentedButton）与年粒度视图：YearBar 年份切换条、本年收支结余摘要卡、12 个月逐月趋势、本年分类饼图（占本年百分比）。区间为当年 1 月 1 日至次年 1 月 1 日左闭右开。
- converted 与 original 两分支同口径：converted 全年选集一次折算，12 个月分区复用同一逐笔值（分区之和守恒全年总额）；original 按月精确铺满全年区间。月模式行为与数值不变。
- 专项入口 [year_report_test.dart](../app/test/pages/year_report_test.dart)；设备验收通过（年总额与设备库核实一致，含闰年 2/29 计入与次年 1/1 排除；5554 指纹因用户本人操作数据偏离基线，已保留不清理）。

**R-03 的实现结果（已完成）：**

- 明细页自定义日期范围：`ReportDateRange`（[report_filter.dart](../app/lib/utils/report_filter.dart)）把界面首末日转成起日零点到结束日次日零点的左闭右开区间，结束早于开始抛错拒绝；`showBillsRangePicker` + `RangeBar`（[range_bar.dart](../app/lib/widgets/range_bar.dart)）提供选择、平移与退出回按月，取消保留选择。
- `billsPeriodModeProvider` / `selectedRangeProvider` / `billsPeriodProvider` / `billsPageBillsProvider` 只影响明细页；`monthBillsProvider` 保持月口径，图表页不受影响（组合筛选属 R-06）。顺带修复折算日小计跨月同日误合并（原按「日」字段匹配）。
- 专项入口 [report_date_range_test.dart](../app/test/utils/report_date_range_test.dart) 与 [bills_range_test.dart](../app/test/pages/bills_range_test.dart)；双雷电跨年范围（2025-12-30 ~ 2026-01-02）明细 / 摘要 / 日小计与设备库一致，取消保留与退出回按月通过，QA 数据精确清理后指纹一致。

**R-04 的实现结果（已完成）：**

- 图表页收入 / 支出切换（[stats_page.dart](../app/lib/pages/stats_page.dart) + `statsTypeProvider`）：饼图与分类排行按维度取同一选集与同一折算快照的 `aggregateCategoryStats(type: 0|1)`；内部分类收入（kind=2）沿用筛选层排除；切换不改动粒度 / 月份 / 币种，趋势保持收支双列。
- 专项入口 [stats_type_test.dart](../app/test/pages/stats_type_test.dart)；双雷电切收支后月 / 年合计与设备库核算一致，上一年空态通过，QA 数据精确清理后指纹一致。

**R-06 历史交接快照（当时未完成；2026-10-23 已补验交付）：**

以下第一组为 **2026-10-21 原快照**：交接提交 `f5822f3`，其下实现提交 `053b224`。保留当时的通过步骤、卡点与排查推断；旧推断不是已确认根因，当前结论与门槛见后续 2026-10-23 续接记录。

- **已实现（代码在 WIP 提交中，应用行为可用）**：图表页粒度新增「范围」（`StatsGranularity.range` + 三段 SegmentedButton），与明细页共享 `selectedRangeProvider`；首次切范围若无既有范围先弹选择器（`pickDateRange`，取消保持原粒度），确认后进入范围粒度；标题栏复用 `RangeBar`（新增 `onExit` 参数，图表页退出回月粒度，明细页保持默认回按月）；周期与标签统一走 `statsPeriodOf`；饼图 / 摘要行 / 明细窗口（R-05）全部跟随范围；趋势月分区**按范围边界裁剪首末月桶**（`_clipPeriodToMonth`）——修复了跨月范围下「分区之和 ≠ 范围总额」的守恒缺陷（原实现用整日历月）；`reportDateRangeLabel` 提取为公共展示标签。
- **测试状态**：新增 [stats_combination_test.dart](../app/test/pages/stats_combination_test.dart) 6 条全过（范围×支出×总览三分区守恒、范围×收入×原币跨年守恒、12 类完整展示且 Σ 扇区==总额、320 小屏长名称不溢出、空态组合、粒度互切保留范围且明细页模式不受影响）；全量 1035/1035；分析 0 error、27 条存量。
- **设备冒烟（.local-dev/verification/r06/smoke-r06.ps1，卡点在此）**：5556 上已通过——范围选择器流程、范围条标题、「范围内支出 / 收入」标题、**分区守恒**（分类行金额滚动求和 == 库内范围总额：支出 3550==3550、收入 500==500）、摘要行与年粒度互切。**卡点**：最后一步点「工资」分类行未打开明细窗口（等待「关闭明细窗口」超时）；点击后的 dump 只见 AppBar（范围条 + 月/年/范围段 + 统计币种），无饼图与分类行。当时尚未核实实际命中的控件，仅将自动化状态 / 懒列表重建时机作为排查推断；不能由旧专项通过推断设备分类行已验收。**建议排查顺序**：(1) 回顶后加更长 settle（2～3 秒）再查找；(2) 改用 R-05 已验证可行的「饼图环带 DPI 坐标点击」作为该步入口，把分类行入口的设备验证单独安排；(3) dump 打印 `category-stats-*` 节点 bounds 与 `QueryController` 异常，确认行是否真的在语义树；(4) 若确认应用缺陷再回代码。另：5554 完全未跑 R-06 冒烟。
- **环境状态（截至交接）**：两台雷电均在运行，已安装含 WIP 的 debug 包；5556 的 QA 数据已由 finally 清理、指纹与基线一致（76D6CC44…），5554 指纹基线 4EA5E74F…。r06 冒烟脚本中支出 / 收入守恒检查已稳定，仅卡窗口打开一步。
- **本机环境要点（全部实测）**：模拟器频繁自动关机 → `ldconsole launch --index 0/1`；广告桌面壳（flysilkworm）占焦点且 am start / BACK 无法拉回 → `ldconsole reboot --index N`（R-05、R-06 各发生一次）；debug 包必须 `gradlew assembleDebug`（flutter 包装固定产 release）；QA 读库依赖 run-as 所以必须可调试包；本机 PowerShell 5.1 逗号优先级高于 `+`（数组元素各自加括号）；部分实例的语义文本落在 content-desc（匹配一律用 text+content-desc 拼接，参考 Get-C13LabelsList / Get-R06RowSum）；uiautomator dump 偶发滞后 → 「查找与点击用同一份节点坐标」。

**2026-10-23 续接结果：R-06 已完成**

- 根审查与独立复审修正图表范围重选误切明细模式：RangeBar.onRangeSelected 只更新共享日期；越界月份 / 平移范围只裁剪选择器草稿，取消保留原值；异步返回检查 mounted，空范围统一回退按月。
- 旧 6 条并未实际点击分类行，本轮加 4 条并补强旧用例。最终 10/10 真实交互与组合专项、1039/1039 全量（runner 61 秒 / 命令 64.2 秒），0 error、27 条原有提示。覆盖确认 / 取消、1999 年及平移边界、USD / JPY、二级 / 未分类、原币切换、窗口与所有分区守恒。
- gradlew assembleDebug 21.6 秒，确认 debuggable，MD5 CA87CDC41A7863E6E074851E3C3D00D0；双机覆盖安装一致。范围 2026-09-28～11-03：5554 支出 814.00 / 收入 27.50，5556 为 35.50 / 5.00，全部与设备库及分类分区一致；工资行窗口均为 1 笔 / 5.00。图表标题重选不切明细模式、取消、USD 空态、CNY / 年 / 范围与退出均通过。
- 两机范围窗口内只修改精确 QA B：5.00→6.00，窗口笔数不变、合计 6.00，图表及库内收入仅 +1.00、支出不变。finally 精确清理全部四条 QA。原账详情、图表、账本、AA 冒烟通过；网络设置未变、当前进程异常和 crash buffer FATAL 均 0。
- 卡点已解决：5556 把整张 Card 合并为含工资的按钮，中心点落在饼图而非下方工资行；5554 行在视口底部被裁剪。先使真实行完整可见再取点，两机开窗通过。币种入口也有整行语义合并，右侧下拉实际位置与中心不同。QA helper 改为 BigInteger，修正收入状态下的支出断言与成功 stderr 误判；脚本不入库。
- 原 FX 键两台均存在，自动联网更新后，先核对原业务指纹及手动数组不变，再经独立逐值审查、exact 当前值事务守卫恢复测试前完整 FX 值，不删除原键。最终含原 FX 的完整六表指纹全部恢复、QA 残留 0，安装包复核一致。当前为便于最终指纹复核保持应用停止，后续启动会正常按缓存规则联网。
- 完成代码 006b2c725111f8d8ed0f70a223963586f7cd051d 已推 origin/Glm5.3F 并核对，完成状态单独文档提交；旧 WIP 与交接提交保留。下一项 R-07，再 R-08。
- **已知展示限制**：超过 12 月的范围趋势仍为固定宽度、只标月份，可能拥挤且跨年标签不含年份；所有月份桶及金额都参与聚合。目标真机、无障碍、后台自动记账及真实平台尚未验收。

**R-05 的实现结果（已完成）：**

- 点击饼图扇区或分类排行打开同一个明细窗口（[category_bills_sheet.dart](../app/lib/pages/category_bills_sheet.dart)）：条件 / 条数 / 合计 + 按日期倒序的账单行（日期、类型、完整路径、币种原币额、实际额差异、总览逐笔折算值与未纳入状态）；一级 root / 二级 exact / 未细分 direct / 未分类 uncategorized 口径与图项一致，合计精确等于图项。
- 点账单复用底部详情；窗口与图表 watch 同一批 provider，编辑 / 删除后自动同步刷新，关闭保留全部筛选。专项入口 [category_bills_sheet_test.dart](../app/test/pages/category_bills_sheet_test.dart)；双雷电两个入口查看并修改通过（改金额后窗口与图表同步刷新，QA 数据精确清理后指纹一致）。

**R-06 保留的验收边界（已完成）：**

- 组合年报 / 范围 / 收入 / 币种 / 一级二级进行完整性验收：空态、未分类、长名称、小屏及金额守恒；超过十类完整展示或明确合并其余，不静默丢掉后续分类。

## 关键源码与不可破坏的规则

| 领域 | 入口与规则 |
|---|---|
| 录入 / 转账 | [edit_bill_page.dart](../app/lib/pages/edit_bill_page.dart)：金额后直接点击币种；跨币确认、预填弹窗、手动输入及异步回调保护 |
| 共享汇率 | [exchange](../app/lib/exchange)、[转账预填入口](../app/lib/exchange/transfer_rate_prefill.dart)、[折算模型](../app/lib/utils/report_conversion.dart)、[口径行](../app/lib/widgets/report_view_hint.dart)、[设置页面](../app/lib/pages/exchange_rates_page.dart)、[providers](../app/lib/providers.dart)：设置页、转账预填与明细 / 图表默认总收支已消费 |
| 数据与事务 | [数据库](../app/lib/data/app_database.dart)：六表 `bills`、`accounts`、`categories`、`aa_groups`、`settlements`、`meta_entries`；迁移、关联与失败回滚不可绕过 |
| 金额 / 余额 / 费用 | [utils](../app/lib/utils)：整数最小单位、BigInt 聚合；双额余额与唯一关联手续费 |
| 明细 / 图表 | [bills_page.dart](../app/lib/pages/bills_page.dart)、[stats_page.dart](../app/lib/pages/stats_page.dart)、[报表聚合](../app/lib/utils/report.dart)、[底部详情](../app/lib/pages/bill_detail_page.dart)、[自定义范围条](../app/lib/widgets/range_bar.dart) |
| 分类 | [层级工具](../app/lib/data/category_hierarchy.dart)、[管理页面](../app/lib/pages/categories_page.dart)：最多两级、同类型；迁移 / 删除转移保持引用与受保护关联 |
| AA / OCR | [AA 服务](../app/lib/sync/aa_sync_service.dart)、[图片识别](../app/lib/recognition/bill_ocr.dart)：既有 AA 限 CNY；OCR 只回填待保存表单 |

- 六币种：CNY、USD、HKD、EUR、JPY、GBP；JPY 0 位，其他当前币种 2 位。单笔持久金额须符合 int64，表达式 / 聚合与比例使用有界 BigInt；禁止混加不同原币、用 double 计算金额或通过展示约值反算。
- 普通账保留交易原币额与账户实际额；转账保留来源本金和目标实际入账额。转账本金不计收支，关联费用支出只计一次，额外扣来源余额；费用子账只能随合法父转账维护。软删除 / 撤销必须保持关联和原有取消状态。
- 保留账单的日期、分类、账户、AA / 结算关联及旧值；已结算原始 AA、结算和异常关联的保护同时在界面与事务执行。不得为新功能放宽这些防护。
- C-12 用 `meta_entries` 表中 `key = exchange_rates.v1` 的单条记录存版本化完整缓存，网络为 Frankfurter / ECB 每日参考数据，8 秒超时 / 32 KiB 上限；手动覆盖只影响该币对及反向，刷新不覆盖它。精度、过期、坏缓存及提交边界详见汇率服务文档。不要新增重复 HTTP 服务、暗改全局手动设置或向网络发送账本数据。
- 月份 / 日期采用本地日历左闭右开区间，不用固定毫秒数代替日历日。统计排除规则、分类完整集合和一级 = 直属 + 二级的守恒必须保留。
- 数据库变更须增加真实旧文件迁移、事务失败回滚 / 重试与原字段保留测试；AA 协议变更另做新旧文件兼容，不能仅加版本号就向旧客户端发送外币。

## 每个小点的强制交付流程

1. **实现前核对基线**：确定一个 ID；记录原数据、相关页面和旧账保护，列明正例 / 反例。每次只保留能完整验收的范围。
2. **实现并重新审查**：复查整个最终 diff 及调用方、事务、精度、异步陈旧结果、取消、失败回滚、生命周期和兼容性。有条件时让独立 AI 只读复审；修复发现的问题后重审受影响部分。
3. **测试**：新增有意义的业务断言，先跑对应专项，再跑有界全量回归与分析。记录实际数量/runner和命令耗时；R-08全量1067条、runner68秒/命令71.6秒，单测试默认20秒。失败先定位修复，不能反复重跑掩盖；依赖下载/构建准备另计。新问题本轮处理，存量提示单列。文档改动至少验证事实、编号、链接和差异，并跑相关短回归，不声称未实现功能已通过。
4. **构建并更新雷电**：功能改动构建当前 APK，以 `install -r` 覆盖两台既有实例、保留数据；核对安装包与本次构建一致。实际操作新行为、失败 / 取消 / 重启等适用场景，再做原账详情、图表、账户、AA 冒烟。只启动成功或看截图不足以验收行为。纯文档变更可核对已验收的同一应用构建与设备基线，不虚构新 APK。
5. **数据与环境复核**：比较测试前后完整业务数据、关联和余额。造账使用唯一 QA 标识；仅按本轮明确 ID 清理自己创建的数据，优先应用操作。必须直接操作数据库时，先核对全部原字段 / schema 与精确目标值，事务、首错停止、回滚保护并独立复核；不能复制上一轮清理 SQL 或删除用户已有汇率设置。恢复原网络设置，检查当前进程异常，禁止清空数据库 / 应用数据代替清理。
6. **记录并提交推送**：更新开发进度 / 测试说明，记录审查、专项 / 回归、设备、数据核对、限制。检查 `git diff --check` 和暂存清单；只提交本点代码、测试、文档，每点单独提交并推送。当前用户指定上述 origin 的 `Glm5.3F`，通过验收后推送该分支；保留既有 WIP 与其他人的修改，不强推。代码与完成状态文档分开提交。通过 `git ls-remote` 核对远端 HEAD。
7. **同步完成状态**：远端代码核对成功后，再勾选本 ID 并同步概览 / 专项计划，采用独立文档提交推送并核对。未完成验收或推送时保留待办并说明阻碍，不把本地通过当成已交付；不顺带勾选后续任务。

设备数据库、原始交易文本、`.aas`、截图、测试日志、QA 脚本、缓存、APK 和密钥不提交。推送前显式检查暂存文件，保留其他人的修改。

## 本机环境与常用命令

以下是本次交接机器的配置，不是其他机器的固定路径。**当前活动 checkout 为 D 盘 `D:\Projects\AAExpenseSplitter`（分支 `Glm5.3F`）**；C 盘 `C:\Users\22686\.codex\worktrees\0981\AAExpenseSplitter` 是 codex 的旧 worktree，其 junction 存储与 `aa-env.ps1` 身份仍指向它，保持原样不要共用。

SDK：Flutter `D:\Dev\flutter`，JDK `D:\Dev\jdk`，Android SDK `D:\Dev\Android\Sdk`；Pub / Gradle 缓存在 `D:\Dev\cache`。C-13 起在 D 盘工作区使用 **`aa-dev-glm.ps1`**（环境变量与 `aa-dev.ps1` 相同，但固定在 `D:\Projects\AAExpenseSplitter\app` 运行，构建产物留在该 checkout 的 `app\build` 真实目录，与 C 盘 worktree 的 junction 存储互不干扰）；旧的 `aa-dev.ps1` 仍绑定 C 盘 worktree，不要在 D 盘检出上使用。

```powershell
# 依次执行，不并行运行同一工程的 Flutter / Dart 命令
& 'D:\Projects\AAExpenseSplitter\.local-dev\aa-dev-glm.ps1' -Tool flutter -ToolArgs @('test','--no-pub','--reporter','expanded','--timeout','20s')
& 'D:\Projects\AAExpenseSplitter\.local-dev\aa-dev-glm.ps1' -Tool flutter -ToolArgs @('analyze','--no-pub')

# 本机 Flutter build 包装曾固定产出 release；QA 依赖 run-as，必须直构 debug。
$env:JAVA_HOME = 'D:\Dev\jdk'
$env:ANDROID_HOME = 'D:\Dev\Android\Sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:GRADLE_USER_HOME = 'D:\Dev\cache\gradle'
$env:TEMP = 'D:\Projects\AAExpenseSplitter\.local-dev\temp-glm'
$env:TMP = $env:TEMP
Push-Location 'D:\Projects\AAExpenseSplitter\app\android'
try {
    & .\gradlew.bat assembleDebug
    if ($LASTEXITCODE -ne 0) { throw 'debug 构建失败' }
} finally { Pop-Location }
```

专项命令在`test`参数后列出本点相关文件；R-08入口为`test/pages/calendar_stats_page_test.dart`，R-07模型入口为`test/utils/calendar_report_test.dart`，R-06历史入口为`test/pages/stats_combination_test.dart`。`aa-dev-glm.ps1`使用调用符`&`，不要点加载该脚本；它末尾有`exit`。同工程SDK命令必须串行。

当前 APK 实体路径（D 盘 checkout 的真实目录，非 junction）：

```text
D:\Projects\AAExpenseSplitter\app\build\app\outputs\apk\debug\app-debug.apk
```

雷电既有实例 0 为 `emulator-5554`（横屏），1 为 `emulator-5556`（竖屏）；包名 `com.aaexpense.aa_expense_splitter`，启动 Activity `.MainActivity`。先用 `adb devices` 确认，不创建新实例替代。

```powershell
& 'D:\Dev\Android\Sdk\platform-tools\adb.exe' devices
& 'D:\Dev\Android\Sdk\platform-tools\adb.exe' -s emulator-5554 install -r 'D:\Projects\AAExpenseSplitter\app\build\app\outputs\apk\debug\app-debug.apk'
& 'D:\Dev\Android\Sdk\platform-tools\adb.exe' -s emulator-5556 install -r 'D:\Projects\AAExpenseSplitter\app\build\app\outputs\apk\debug\app-debug.apk'
```

本机雷电 `D:\software\leidian\LDPlayer14\ldconsole.exe`。**C-13 再次证实：无论是宿主 `call.network offline` 还是客户机设置里关闭 WLAN，都会同时断开该实例的 adbd，且软件手段（ldconsole / adb reconnect / 实例重启前 WLAN 未恢复）无法恢复**；实例 1 曾因此需人工在窗口内重开 WLAN 后重启实例才恢复。断网类验收必须先准备不依赖 ADB 的恢复手段，或改用无网络依赖的验证方式。这些是设备控制经验，不能当成 App 缺陷或真实支付平台验收。

本机验证记录只放`D:\Projects\AAExpenseSplitter\.local-dev\verification`，R-08交付证据为`r08`，r03～r07和c13保留历史证据 / 辅助脚本。R-08已按事务内完整守卫清理本轮4QA，原始完整六表含FX与基线相同，未做网络切换或FX修复；两机已force-stop，后续正常启动仍可能按缓存规则联网。新轮次重新捕获基线并使用自己的明确QA身份，不照搬旧SQL或覆盖用户数据。PowerShell5.1含中文脚本需UTF-8 BOM。上述本机路径/脚本不提交仓库，原未跟踪`TestPictures/data/`保持不动。

## 每次交付回复模板

说明“完成哪个 ID / 用户可见变化”，再列实际审查结论、专项与全量数量 / 耗时、分析存量、两台雷电操作 / 原数据核对、代码与文档提交 / 远端核对及下一 ID。有未通过项就明确保留待办，不能只说“测试通过、已提交”。

R-07 / R-08已交付，下一项 **D-01完整备份恢复（未实现）**，随后P2-02、P1-05和AA-01～04。每个编号分别完成审查、全量/专项、双设备及远端核对，不批量勾选。
