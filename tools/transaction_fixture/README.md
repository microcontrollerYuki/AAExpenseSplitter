# 独立交易页面测试 App

此工程服务于 P0-01：提供可重复打开的脱敏交易页面，供后续无障碍节点采集和截图 OCR 验收。它使用独立包名 `com.aaexpense.transactionfixture`，与正式记账 App 同时安装，不读取或修改正式账本，不调用支付平台。

当前交付的是页面与静态专项测试。2026-10-09 已通过 debug 构建、19 条专项和两台雷电的六场景节点 / 画面、选择与返回验收；记录见 [开发进度](../../Docs/开发进度.md)。当前未接入正式 App 的无障碍服务或截图 OCR，不能将页面验收视为识别链路通过。

## 工程与发布隔离

- 独立 `settings.gradle` 只包含 `:fixtureApp`，不修改主工程的 Flutter / Android 配置。构建时复用主工程现有 Gradle wrapper，所有产物写入本目录。
- 使用已有 AGP 9.1.0、Gradle 9.3.1、Android SDK 36、Java 17；只使用 Android framework 和 Java，无第三方运行依赖。`android.builtInKotlin=false` 禁用 Java 工程不需要的内置 Kotlin。
- 全部页面代码、JSON、资源和 launcher manifest 位于 `src/debug`；`src/main` 只有空 manifest。
- debug manifest 设置 `testOnly=true`、`allowBackup=false`，安装必须加 `adb install -t`；不声明网络权限或无障碍服务。
- `androidComponents.beforeVariants` 禁用 release variant，不生成可发布的 fixture APK。
- 正式 App 当前未注册无障碍服务。本工程不会自动加入其监听名单；后续 P3 接入时只能在正式 App 的 debug 配置允许 fixture 包，release 白名单须另行验证不包含它。

## 固定样例

唯一数据源是 `fixtureApp/src/debug/assets/scenarios.json`。`ScenarioCatalog` 加载后，节点页和 Canvas 页渲染相同的 `Scenario.lines`，两种模式不各写一套交易文本。

| Intent 的 `scenario` 值 | 页面模式 | 交易状态 | 显示金额 | 正确入账结果 |
|---|---|---|---|---|
| `nodes_success` | 可读 TextView 节点 | 支付成功 | 实付 ¥12.34 | 支出 1234 分 |
| `nodes_failed` | 可读 TextView 节点 | 支付失败 | 尝试支付 ¥12.34 | 不入账 |
| `nodes_multi` | 可读 TextView 节点 | 支付成功 | 原价 ¥100.00、优惠 ¥10.00、实付 ¥90.00、余额 ¥1,234.56 | 支出 9000 分 |
| `canvas_success` | Canvas 绘制交易文本 | 支付成功 | 实付 ¥12.34 | 未来 OCR 应识别支出 1234 分 |
| `canvas_failed` | Canvas 绘制交易文本 | 支付失败 | 尝试支付 ¥12.34 | 不入账 |
| `canvas_multi` | Canvas 绘制交易文本 | 支付成功 | 与 `nodes_multi` 相同的四个金额 | 未来 OCR 应识别支出 9000 分 |

商户、支付方式和时间均固定；每个案例有唯一的 `FIXTURE-...` 交易单号。`expectedRecordedCents` 是测试真值；失败案例为 `null`。该值不作为隐藏节点提供给采集器。

节点页使用稳定的 `fixture_status`、`fixture_amount`、`fixture_transaction_id` 等资源 ID。Canvas 页只绘制文字，不把交易文字放入 `text`、`contentDescription` 或虚拟节点；页面外的标题和“返回样例”按钮也不携带交易状态、金额或单号。系统窗口或按钮节点仍然可能存在，“空节点”验收指交易信息未出现在节点树。

Canvas 文字会随可用宽度折行，页面支持滚动。验收时先确认交易信息确实可见，再对照节点导出；不要把被裁切或滚出屏幕的信息当成 OCR 成功样例。

## 构建与静态专项

以下命令从仓库根目录执行，使用已有 `JAVA_HOME`、`ANDROID_HOME` 和 `GRADLE_USER_HOME`。当前本机对应 `D:\Dev\jdk`、`D:\Dev\Android\Sdk`、`D:\Dev\cache\gradle`，不将机器路径写入版本控制。独立工程需要本地 SDK 路径时，可创建已忽略的 `local.properties`。

```powershell
python -m unittest discover -s tools/transaction_fixture/tests -v

.\app\android\gradlew.bat -p .\tools\transaction_fixture :fixtureApp:assembleDebug --offline --console=plain
```

专项测试只使用 Python 标准库，检查样例矩阵、金额真值、失败不记账、唯一交易标识及工程隔离。它包含源码边界检查，不执行 Android UI、无障碍服务或 OCR；实际渲染仍须在设备验证。

APK 路径：`tools/transaction_fixture/fixtureApp/build/outputs/apk/debug/fixtureApp-debug.apk`。正式 Flutter APK 的路径和包名不变。新克隆环境若没有 `app/android/gradlew.bat`，须先按主工程流程准备 Flutter Android wrapper，再运行本工程命令；不额外下载另一套 Gradle。

## 雷电短验收

先记录两台设备的 API / Android 版本，以及无障碍设置入口是否存在。目标真机未连接时记录“待验证”，不写成已通过。

```powershell
adb -s emulator-5554 shell getprop ro.build.version.sdk
adb -s emulator-5554 shell getprop ro.build.version.release
adb -s emulator-5554 shell cmd package resolve-activity --brief -a android.settings.ACCESSIBILITY_SETTINGS

adb -s emulator-5554 install -r -t tools/transaction_fixture/fixtureApp/build/outputs/apk/debug/fixtureApp-debug.apk
adb -s emulator-5554 shell am start -n com.aaexpense.transactionfixture/.MainActivity --es scenario nodes_multi
adb -s emulator-5554 shell uiautomator dump /sdcard/transaction-fixture-nodes.xml
adb -s emulator-5554 shell cat /sdcard/transaction-fixture-nodes.xml

adb -s emulator-5554 shell am start -n com.aaexpense.transactionfixture/.MainActivity --es scenario canvas_multi
adb -s emulator-5554 shell uiautomator dump /sdcard/transaction-fixture-canvas.xml
adb -s emulator-5554 shell cat /sdcard/transaction-fixture-canvas.xml
```

1. 可读页的 dump 应含成功状态、四个金额、商户和交易单号。Canvas 页画面仍显示这些内容，但 dump 不含对应的交易文本；标题与返回按钮可以出现。
2. 分别打开两种模式的成功、失败和多金额案例，确认状态、金额与表格一致；重复打开同一案例，单号和时间保持不变。
3. 用界面“返回样例”切换案例，验证每个按钮只打开对应页面。未知 `scenario` 应显示选择页面及提示，不能偷偷回退到成功交易。
4. 将设备参数替换为 `emulator-5556`，复验另一台雷电。确认正式记账 App 仍可正常启动，既有账单未被 fixture 修改。
5. 检查 `:fixtureApp:tasks --all` 没有 `assembleRelease` / `bundleRelease`，检查 debug 合并 manifest 的独立 applicationId 和 `testOnly`。未来正式 App 有服务配置后，再验证其 release 产物不包含 fixture 监听配置。

UI dump 只能证明当前交易文本的节点可见性；不代替 P3 的应用自身服务链路，也不代替 P5 的应用自身截图能力。`FLAG_SECURE` 与截图失败分支留待对应步骤补充。
