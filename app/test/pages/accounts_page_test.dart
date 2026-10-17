import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/accounts_page.dart';

import '../helpers/test_support.dart';

Future<void> _saveEditedAccount(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('保存'));
  });
  for (
    var i = 0;
    i < 50 && find.byType(AlertDialog).evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(AlertDialog), findsNothing);
  await settleProviders(tester);
}

void main() {
  testWidgets('总资产与账户列表渲染（含不计入净资产的账户）', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertAccount(
      id: 'acc_virtual',
      name: '公交卡',
      emoji: '🚌',
      type: 3,
      initBalance: 5000,
      includeNetWorth: false,
      sort: 9,
    );
    await db.upsertBill(
      id: 'b1',
      type: 0,
      amount: 2000,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: 1,
    ); // 现金支出 20.00

    await pumpPage(tester, const AccountsPage(), db: db);

    // 预置现金 0 + 支出 -20 = -20.00（计入净资产）
    // 公交卡 50.00 不计入 → 总资产 -20.00
    expect(find.text('总资产（计入净资产的账户）'), findsOneWidget);
    expect(find.text('¥ -20.00'), findsOneWidget);
    expect(find.text('公交卡'), findsOneWidget);
    expect(find.text('虚拟账户'), findsNWidgets(3)); // 微信/支付宝/公交卡副标题

    await disposePage(tester, db);
  });

  testWidgets('添加账户：名称为空提示', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());

    await tester.tap(find.byTooltip('添加账户'));
    await tester.pumpAndSettle();
    expect(find.text('添加账户'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('请填写账户名称'), findsOneWidget);
    // 对话框仍在
    expect(find.text('取消'), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('添加账户：填名称保存成功入库', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());

    await tester.tap(find.byTooltip('添加账户'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '名称'), '交通银行储蓄卡');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('交通银行储蓄卡'), findsOneWidget); // 列表出现新账户
    final acc = await db.getAllAccounts();
    expect(acc.any((a) => a.name == '交通银行储蓄卡'), isTrue);

    await disposePage(tester, db);
  });

  testWidgets('添加账户：与已有账户重名被拒绝', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());

    await tester.tap(find.byTooltip('添加账户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), '现金');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('已有同名账户，不允许重名'), findsOneWidget);
    // 对话框仍在、未入库
    expect(find.text('取消'), findsOneWidget);
    final acc = await db.getAllAccounts();
    expect(acc.where((a) => a.name == '现金').length, 1);

    await disposePage(tester, db);
  });

  testWidgets('添加账户：AA- 前缀变体重名同样被拒绝', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());

    await tester.tap(find.byTooltip('添加账户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), 'AA-现金');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('已有同名账户，不允许重名'), findsOneWidget);
    final acc = await db.getAllAccounts();
    expect(acc.any((a) => a.name == 'AA-现金'), isFalse);

    await disposePage(tester, db);
  });

  testWidgets('添加账户：金额输入自动千分位且拒绝非法字符', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());

    await tester.tap(find.byTooltip('添加账户'));
    await tester.pumpAndSettle();

    final balanceField = find.widgetWithText(TextField, '期初余额（元）');
    await tester.enterText(find.widgetWithText(TextField, '名称'), '测试');
    await tester.enterText(balanceField, '1234567');
    await tester.pump();
    // formatter 分组：1234567 → 1,234,567
    final ctl = tester.widget<TextField>(balanceField).controller;
    expect(ctl!.text, '1,234,567');

    // 三位小数被拒（保留旧值）
    await tester.enterText(balanceField, '1,234,567.899');
    await tester.pump();
    expect(ctl.text, '1,234,567');

    // 清空
    await tester.enterText(balanceField, '');
    await tester.pump();
    expect(ctl.text, '');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await disposePage(tester, db);
  });

  testWidgets('编辑账户：改 emoji、切换计入净资产并保存', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());

    // 「现金」同时是账户名与类型副标题，取首个（title）
    await tester.tap(find.text('现金').first);
    await tester.pumpAndSettle();
    // 新交互：先进账户信息页，按下「修改」才打开编辑弹窗
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(find.text('编辑账户'), findsOneWidget);

    // 初始值为现金 💵；🪙 不在账户列表 emoji 中，避免定位歧义
    await tester.tap(find.text('🪙'));
    await tester.pump();

    // 关闭「计入总资产」开关
    await tester.tap(find.text('计入总资产'));
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final acc = await db.getAccount('acc_cash');
    expect(acc!.emoji, '🪙');
    expect(acc.includeNetWorth, isFalse);

    await disposePage(tester, db);
  });

  testWidgets('删除账户：有关联账单被阻止', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'b1',
      type: 0,
      amount: 100,
      categoryId: 'cat_food',
      accountId: 'acc_wechat',
      dateMs: 1,
    );

    await pumpPage(tester, const AccountsPage(), db: db);

    await tester.tap(find.text('微信'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(find.textContaining('已有 1 笔账单，无法删除'), findsOneWidget);
    expect(await db.getAccount('acc_wechat'), isNotNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await disposePage(tester, db);
  });

  testWidgets('账户连续两次编辑保留最新名称图标余额和资产设置', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());

    await tester.tap(find.text('现金').first);
    await settleProviders(tester);
    await tester.tap(find.text('修改'));
    await settleProviders(tester);
    await tester.enterText(find.widgetWithText(TextField, '名称'), '备用现金');
    await tester.tap(find.text('🪙'));
    await tester.enterText(find.widgetWithText(TextField, '期初余额（元）'), '100');
    await tester.tap(find.text('计入总资产'));
    tester.testTextInput.hide();
    await _saveEditedAccount(tester);

    expect(find.text('🪙 备用现金'), findsOneWidget);
    expect(find.text('¥ 100.00'), findsOneWidget);
    await tester.tap(find.text('修改'));
    await settleProviders(tester);
    final nameField = tester.widget<TextField>(
      find.widgetWithText(TextField, '名称'),
    );
    final balanceField = tester.widget<TextField>(
      find.widgetWithText(TextField, '期初余额（元）'),
    );
    expect(nameField.controller!.text, '备用现金');
    expect(balanceField.controller!.text, '100.00');
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );

    // 第二次只改名称，其他属性不能被第一次进入信息页的快照覆盖。
    await tester.enterText(find.widgetWithText(TextField, '名称'), '备用现金二次');
    tester.testTextInput.hide();
    await _saveEditedAccount(tester);
    expect(find.text('🪙 备用现金二次'), findsOneWidget);
    expect(find.text('¥ 100.00'), findsOneWidget);
    final saved = await db.getAccount('acc_cash');
    expect(saved!.name, '备用现金二次');
    expect(saved.emoji, '🪙');
    expect(saved.initBalance, 10000);
    expect(saved.includeNetWorth, isFalse);
    await disposePage(tester, db);
  });

  testWidgets('账户信息打开期间记录被删除后不再提供修改入口', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());
    await tester.tap(find.text('支付宝'));
    await settleProviders(tester);
    expect(find.text('修改'), findsOneWidget);

    // 模拟其他入口删除账户；信息页必须响应真实数据库变化。
    await tester.runAsync(() => db.deleteAccount('acc_alipay'));
    await settleProviders(tester);
    expect(find.text('修改'), findsNothing);
    expect(find.text('支付宝'), findsNothing);
    expect(await db.getAccount('acc_alipay'), isNull);
    await disposePage(tester, db);
  });

  testWidgets('删除账户：无账单时成功', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());

    await tester.tap(find.text('支付宝'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(await db.getAccount('acc_alipay'), isNull);
    expect(find.text('支付宝'), findsNothing);

    await disposePage(tester, db);
  });
}
