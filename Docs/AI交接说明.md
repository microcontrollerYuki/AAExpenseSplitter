# AI 开发交接说明

交接日期：**2026-10-17**。面向接手本项目的 AI 开发代理。先核对实际仓库与最新文档，再动手；本文是交接快照，后续任务勾选以 [总 TODO](TODO-无障碍自动记账.md) 为准，验证结果以 [开发进度](开发进度.md) 和 [测试说明](测试说明.md) 为准。不要把历史档案里的“下一项”当成当前任务。

## 用户目标与工作要求

项目是离线优先的 Android 个人记账与双人 AA 工具，最终目标为通过无障碍读取受支持支付 App 的交易屏幕，先生成待核对候选，再按用户规则自动记账。

**当前先完善与 AA 无关的普通记账、多币种和报表；AA 增强与无障碍继续延后。一次只推进一个可独立验收的小点，不把多个未验证功能合在一起提交。每完成一个小点，必须重新审查代码、运行新功能专项与回归测试、覆盖安装两台既有雷电并实际操作，确认无问题后提交并推送；没有通过的门槛不得记作已完成。**

与用户用中文沟通。明确说明交付行为、测试数量 / 耗时、设备结果、限制和提交，不只给计划或口头声称测试通过。长操作期间持续提供简短进度。

最终产品仍须满足 [总 TODO 的最终验收标准](TODO-无障碍自动记账.md#最终验收标准)：真实受支持平台正确识别完成交易的金额 / 方向 / 时间 / 账户 / 分类，不确定或未完成交易待核对；用户启用后界面关闭仍能后台入账，暂停 / 撤销权限后停止；重复事件、节点 / OCR 双命中、重启 / 升级不重记，不误合并真实同额两笔；旧账、余额、AA 和结算保持正确，识别记录可追溯、修改与撤销。系统强制停止后的恢复限制须如实说明。每个阶段按证据交付，不能用雷电合成场景替代真机 / 真实平台验收。

## 当前可靠基线

| 项目 | 本次交接状态 |
|---|---|
| 仓库 / 分支 | `https://github.com/microcontrollerYuki/AAExpenseSplitter.git` / `Glm5.3F`（已合并 `codex/stabilize-aa` 与远端 main） |
| 最近功能提交 | C-13：`e79d24a409eaa68115889e5c3c9671a75b125dd0`，已推送并核对远端 |
| 版本 / 数据库 | `app/pubspec.yaml` 为 `0.2.0+5000`；Drift / SQLite schema 6 |
| 总任务 | 65 个唯一编号，29 完成 / 36 待办；C 多币种阶段 13 / 13。数量不是产品完成率 |
| 最近专项 / 全量 | C-13 专项 108/108；全量 977/977，runner 约 55 秒、命令约 59 秒 |
| 分析 | 0 error、27 条原有 warning / info；本轮新增 lint 已处理，不能宣称存量清零 |
| 设备验收 | 两台既有雷电已安装 C-13，联网预填 / 手动率 / 实际额 / 手续费组合 / 旧账回显 / 冒烟通过，业务六表指纹与基线一致；设备级断网操作遗留（雷电 WLAN 与 adbd 联动断开，详见开发进度 C-13 限制段） |
| 当前下一项 | **R-09 同一汇率快照逐笔折算 CNY** |

本次交接文档同时同步 C-12 完成状态。最终文档提交号从 `git log` 读取，不在本文写入自身提交号。上述测试是上一轮已执行的基线，接手后的改动仍须重新验证。

已交付：手动收支、本人转账、六币种账户及实际双额、转账内手续费、两级分类 / 宫格选择 / 迁移 / 删除转移、手选年月、底部账单详情、原币月统计 / 分类 / 六个月趋势、共享汇率设置、转账汇率预填与手动覆盖、图片 OCR 辅助录入、仅 CNY 的双人 AA 与加密文件交换。完整功能 / 限制见 [项目概览](README.md)。

尚未交付：默认折算总收支、年报 / 自定义范围 / 收入独立报表 / 统计明细 / 日历、AA 完整分类路径兼容、无障碍与后台自动入账。预算、CSV、整库备份、回收站仍为占位。现有图片 OCR 和独立测试 App 不代表无障碍已实现；真机、真实支付平台版本、iOS、正式签名发布也未验收。

## 接手时先执行

1. 读取本仓库适用的 `AGENTS.md` 等指令（如果存在），检查 `git status --short`、当前分支、`git log -5 --oneline`、`git remote -v`。保存并理解已有修改，不使用强制 reset、清空工作区、强推或丢弃不属于自己的改动。
2. 按顺序阅读 [项目概览](README.md) → [开发进度](开发进度.md) → [总 TODO](TODO-无障碍自动记账.md) → [测试说明](测试说明.md) → 对应专项计划。当前下一步另读 [多币种与报表计划](下一版本计划-多币种与报表.md) 与 [汇率服务](汇率服务.md)。档案和 [早期设计框架](AA记账-功能设计框架.md) 只作历史参考。
3. 确认正在修改哪一份 checkout，SDK / 缓存脚本是否指向它，ADB 对应哪两台原实例。不要因为存在 D 盘主目录而切到另一份代码，也不要重建模拟器或清除应用数据。
4. 选一个 TODO ID，说明本轮范围、受影响数据和正反例。当前应选 R-09；本轮无需同时实施 R-10 或重做 C-13。

## 任务顺序与下一小点

按 **R-09 → R-10 → R-02 → R-03 → R-04 → R-05 → R-06 → R-07 → R-08** 逐点交付，保留原编号，不按编号大小改顺序。随后再恢复 P1-05、P0-01 剩余能力探测、P2～P7。全部细项与验收要求保留在总 TODO，不另造一份状态清单。

**C-13 的实现结果（已完成）：**

- `TransferRatePrefill` 接口（[transfer_rate_prefill.dart](../app/lib/exchange/transfer_rate_prefill.dart)）冻结不可变 `RateQuote` 生成跨币入账候选；弹窗显示方向 / 来源 / 时间 / 手动 / 过期状态，自定义汇率或实际额均为手动输入，采用即显式确认；JPY 只舍入一次。
- 换账户 / 本金 / 币种后旧确认失效；迟到刷新只更新候选显示；历史转账优先回显已保存双额；离线缺率可人工确认；pumpPage 默认惰性注入，页面测试零网络。同签名内快照转旧不自愈是已知显示限制。
- 专项入口 [transfer_rate_prefill_test.dart](../app/test/pages/transfer_rate_prefill_test.dart)；设备级断网操作因雷电 WLAN 与 adbd 联动断开而遗留（R-09 如需断网验证，先解决该环境约束）。
- 同时回归 C-11：手续费按来源币种额外支付，来源改变后须重确认，目标入账确认独立维护；汇率预填不绕过总扣款、关联事务及历史保护（专项已覆盖）。
- 专项覆盖方向 / 反向、JPY / 舍入、手动优先、迟到成功与失败、取消 / 销毁、账户 / 本金改变、缺率 / 过期、历史编辑等，已随 [transfer_rate_prefill_test.dart](../app/test/pages/transfer_rate_prefill_test.dart) 交付；双雷电联网预填、手动率 / 实际额、余额、费用及旧账已通过。

C-13 改动的关键路径：编辑页 `_pickTransferIncoming` / `_TransferIncomingDialog` / `_receivedButtonLabel` / `_ensureTransferRateQuote`，保存路径 `saveTransferWithFee` 未变。既有回归入口为 [转账录入](../app/test/pages/currency_transfer_entry_test.dart)、[手续费录入](../app/test/pages/transfer_fee_entry_test.dart)、[双额数据层](../app/test/data/cross_currency_transfer_test.dart)。

后续 R-09 冻结同一汇率快照、逐笔折算 CNY，所有分区共用同一逐笔值；缺率明确列出未纳入项，部分结果不能称完整总额。R-10 才接入明细与图表默认总收支，两处原币筛选各自独立，账单列表仍全币种可见。年报、范围、收入、统计账单窗口和日历沿用同一集合与口径，详见专项计划。

## 关键源码与不可破坏的规则

| 领域 | 入口与规则 |
|---|---|
| 录入 / 转账 | [edit_bill_page.dart](../app/lib/pages/edit_bill_page.dart)：金额后直接点击币种；跨币确认、预填弹窗、手动输入及异步回调保护 |
| 共享汇率 | [exchange](../app/lib/exchange)、[转账预填入口](../app/lib/exchange/transfer_rate_prefill.dart)、[设置页面](../app/lib/pages/exchange_rates_page.dart)、[providers](../app/lib/providers.dart)：设置页与转账预填已消费，报表折算尚未接入 |
| 数据与事务 | [数据库](../app/lib/data/app_database.dart)：六表 `bills`、`accounts`、`categories`、`aa_groups`、`settlements`、`meta_entries`；迁移、关联与失败回滚不可绕过 |
| 金额 / 余额 / 费用 | [utils](../app/lib/utils)：整数最小单位、BigInt 聚合；双额余额与唯一关联手续费 |
| 明细 / 图表 | [bills_page.dart](../app/lib/pages/bills_page.dart)、[stats_page.dart](../app/lib/pages/stats_page.dart)、[报表聚合](../app/lib/utils/report.dart)、[底部详情](../app/lib/pages/bill_detail_page.dart) |
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
3. **测试**：新增有意义的业务断言，先跑对应专项，再跑有界全量回归与分析。记录实际数量 / runner 和命令耗时；当前约 960 条 / 60 秒，单测试默认 20 秒。失败先定位修复，不能反复重跑掩盖；依赖下载 / 构建准备另计。新问题本轮处理，存量提示单列。文档改动至少验证事实、编号、链接和差异，并跑相关短回归，不声称未实现功能已通过。
4. **构建并更新雷电**：功能改动构建当前 APK，以 `install -r` 覆盖两台既有实例、保留数据；核对安装包与本次构建一致。实际操作新行为、失败 / 取消 / 重启等适用场景，再做原账详情、图表、账户、AA 冒烟。只启动成功或看截图不足以验收行为。纯文档变更可核对已验收的同一应用构建与设备基线，不虚构新 APK。
5. **数据与环境复核**：比较测试前后完整业务数据、关联和余额。造账使用唯一 QA 标识；仅按本轮明确 ID 清理自己创建的数据，优先应用操作。必须直接操作数据库时，先核对全部原字段 / schema 与精确目标值，事务、首错停止、回滚保护并独立复核；不能复制上一轮清理 SQL 或删除用户已有汇率设置。恢复原网络设置，检查当前进程异常，禁止清空数据库 / 应用数据代替清理。
6. **记录并提交推送**：更新开发进度 / 测试说明，记录审查、专项 / 回归、设备、数据核对、限制。检查 `git diff --check` 和暂存清单；只提交本点代码、测试、文档，每点单独提交并推送。当前用户已授权上述 origin 的 `codex/stabilize-aa`，按工具实际权限执行，不强推。通过 `git ls-remote` 核对远端 HEAD。
7. **同步完成状态**：远端代码核对成功后，再勾选本 ID 并同步概览 / 专项计划，采用独立文档提交推送并核对。未完成验收或推送时保留待办并说明阻碍，不把本地通过当成已交付；不顺带勾选后续任务。

设备数据库、原始交易文本、`.aas`、截图、测试日志、QA 脚本、缓存、APK 和密钥不提交。推送前显式检查暂存文件，保留其他人的修改。

## 本机环境与常用命令

以下是本次交接机器的配置，不是其他机器的固定路径。**当前活动 checkout 为 D 盘 `D:\Projects\AAExpenseSplitter`（分支 `Glm5.3F`）**；C 盘 `C:\Users\22686\.codex\worktrees\0981\AAExpenseSplitter` 是 codex 的旧 worktree，其 junction 存储与 `aa-env.ps1` 身份仍指向它，保持原样不要共用。

SDK：Flutter `D:\Dev\flutter`，JDK `D:\Dev\jdk`，Android SDK `D:\Dev\Android\Sdk`；Pub / Gradle 缓存在 `D:\Dev\cache`。C-13 起在 D 盘工作区使用 **`aa-dev-glm.ps1`**（环境变量与 `aa-dev.ps1` 相同，但固定在 `D:\Projects\AAExpenseSplitter\app` 运行，构建产物留在该 checkout 的 `app\build` 真实目录，与 C 盘 worktree 的 junction 存储互不干扰）；旧的 `aa-dev.ps1` 仍绑定 C 盘 worktree，不要在 D 盘检出上使用。

```powershell
# 依次执行，不并行运行同一工程的 Flutter / Dart 命令
& 'D:\Projects\AAExpenseSplitter\.local-dev\aa-dev-glm.ps1' -Tool flutter -ToolArgs @('test','--no-pub','--reporter','expanded','--timeout','20s')
& 'D:\Projects\AAExpenseSplitter\.local-dev\aa-dev-glm.ps1' -Tool flutter -ToolArgs @('analyze','--no-pub')
& 'D:\Projects\AAExpenseSplitter\.local-dev\aa-dev-glm.ps1' -Tool flutter -ToolArgs @('build','apk','--debug','--no-pub')
```

专项命令在 `test` 参数后列出本点相关文件；当前 C-13 的四文件命令见测试说明。`aa-dev-glm.ps1` 使用调用符 `&`，不要点加载该脚本；它末尾有 `exit`。同工程 SDK 命令并发会引发 native assets / 生成物竞争。

当前 APK 实体路径（D 盘 checkout 的真实目录，非 junction）：

```text
D:\Projects\AAExpenseSplitter\app\build\app\outputs\flutter-apk\app-debug.apk
```

雷电既有实例 0 为 `emulator-5554`（横屏），1 为 `emulator-5556`（竖屏）；包名 `com.aaexpense.aa_expense_splitter`，启动 Activity `.MainActivity`。先用 `adb devices` 确认，不创建新实例替代。

```powershell
& 'D:\Dev\Android\Sdk\platform-tools\adb.exe' devices
& 'D:\Dev\Android\Sdk\platform-tools\adb.exe' -s emulator-5554 install -r 'D:\Projects\AAExpenseSplitter\app\build\app\outputs\flutter-apk\app-debug.apk'
& 'D:\Dev\Android\Sdk\platform-tools\adb.exe' -s emulator-5556 install -r 'D:\Projects\AAExpenseSplitter\app\build\app\outputs\flutter-apk\app-debug.apk'
```

本机雷电 `D:\software\leidian\LDPlayer14\ldconsole.exe`。**C-13 再次证实：无论是宿主 `call.network offline` 还是客户机设置里关闭 WLAN，都会同时断开该实例的 adbd，且软件手段（ldconsole / adb reconnect / 实例重启前 WLAN 未恢复）无法恢复**；实例 1 曾因此需人工在窗口内重开 WLAN 后重启实例才恢复。断网类验收必须先准备不依赖 ADB 的恢复手段，或改用无网络依赖的验证方式。这些是设备控制经验，不能当成 App 缺陷或真实支付平台验收。

本机验证记录只放 `D:\Projects\AAExpenseSplitter\.local-dev\verification`。C-13 子目录记录本轮证据（QA 脚本 / 快照 / 清理 SQL / 截图），不要重跑其中旧脚本，未来数据基线已不同；`.local-dev/fix-bom.ps1` 用于给 C-13 的 PowerShell 脚本补 UTF-8 BOM（PowerShell 5.1 解析中文需要）。此路径和环境脚本不随 Git 仓库分发，其他机器应按实际 SDK / 模拟器配置等价流程。

## 每次交付回复模板

说明“完成哪个 ID / 用户可见变化”，再列实际审查结论、专项与全量数量 / 耗时、分析存量、两台雷电操作 / 原数据核对、代码与文档提交 / 远端核对及下一 ID。有未通过项就明确保留待办，不能只说“测试通过、已提交”。

本轮预期下一次功能交付是 **R-09**，完成后才开始 **R-10**。
