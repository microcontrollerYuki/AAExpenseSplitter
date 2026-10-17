import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/pages/accounts_page.dart';
import 'package:aa_expense_splitter/utils/currency.dart';

import '../helpers/test_support.dart';

Future<void> _account(
  AppDatabase db,
  String id,
  String code,
  int opening, {
  bool include = true,
}) => db.upsertAccount(
  id: id,
  name: '账户$id',
  emoji: '💰',
  type: 3,
  initBalance: opening,
  includeNetWorth: include,
  sort: 10,
  currency: code,
);

Future<void> _choose(WidgetTester tester, String text) async {
  final field = find.byKey(const ValueKey('account_currency'));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, {bool closes = true}) async {
  tester.testTextInput.hide();
  await tester.runAsync(() async => tester.tap(find.text('保存')));
  await settleProviders(tester);
  for (
    var i = 0;
    i < 30 &&
        (closes
            ? find.byType(AlertDialog).evaluate().isNotEmpty
            : find.text('保存中…').evaluate().isNotEmpty);
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await settleProviders(tester);
  }
  expect(find.byType(AlertDialog), closes ? findsNothing : findsOneWidget);
}

Future<void> _edit(WidgetTester tester, String name) async {
  await tester.ensureVisible(find.text(name).first);
  await tester.tap(find.text(name).first);
  await settleProviders(tester);
  await tester.tap(find.text('修改'));
  await settleProviders(tester);
}

void main() {
  testWidgets('净资产超过单笔int64上限仍完整为正，窄屏大字体不截断', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = TestAppDatabase();
    await _account(db, 'max', 'CNY', 9223372036854775807);
    await _account(db, 'one', 'CNY', 1);
    await pumpPage(tester, const AccountsPage(), db: db);
    await settleProviders(tester);
    final amount = find.text('¥ 92,233,720,368,547,758.08');
    expect(amount, findsOneWidget);
    expect(tester.getRect(amount).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(amount).right, lessThanOrEqualTo(320));
    expect(find.text('¥ -92,233,720,368,547,758.08'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('净资产按币种分别列出，账户余额采用实际额且排除不计入账户', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD', 1234);
    await _account(db, 'jpy', 'JPY', 3456);
    await _account(db, 'eur', 'EUR', 900, include: false);
    await db.upsertBill(
      id: 'actual',
      type: 0,
      amount: 1000,
      currency: 'USD',
      accountAmount: 7200,
      accountId: 'acc_cash',
      dateMs: 1,
    );
    await db.upsertBill(
      id: 'yen-income',
      type: 1,
      amount: 44,
      currency: 'JPY',
      accountId: 'jpy',
      dateMs: 1,
    );
    await pumpPage(tester, const AccountsPage(), db: db);
    await settleProviders(tester);
    expect(find.text('¥ -72.00'), findsOneWidget);
    expect(find.text('USD 12.34'), findsOneWidget);
    expect(find.text('JPY 3,500'), findsOneWidget);
    expect(find.text('EUR 9.00'), findsNothing);
    expect(find.text('-72.00'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('真实新建美元负期初余额，不按人民币或浮点换算', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());
    await tester.tap(find.byTooltip('添加账户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), '美元储蓄');
    await _choose(tester, 'USD · 美元');
    await tester.enterText(
      find.widgetWithText(TextField, '期初余额（USD）'),
      '-12.34',
    );
    await _save(tester);
    final saved = (await db.getAllAccounts()).singleWhere(
      (a) => a.name == '美元储蓄',
    );
    expect(saved.currency, 'USD');
    expect(saved.initBalance, -1234);
    expect(find.text('USD -12.34'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('真实新建日元，千分位整数保存并拒绝小数输入', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());
    await tester.tap(find.byTooltip('添加账户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), '日元钱包');
    await _choose(tester, 'JPY · 日元');
    final field = find.widgetWithText(TextField, '期初余额（JPY）');
    await tester.enterText(field, '1234');
    expect(tester.widget<TextField>(field).controller!.text, '1,234');
    await tester.enterText(field, '1234.5');
    expect(tester.widget<TextField>(field).controller!.text, '1,234');
    await _save(tester);
    final saved = (await db.getAllAccounts()).singleWhere(
      (a) => a.name == '日元钱包',
    );
    expect(saved.currency, 'JPY');
    expect(saved.initBalance, 1234);
    expect(find.text('JPY 1,234'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('未引用账户换为JPY不静默截断旧小数，明确修正后再保存', (tester) async {
    final db = TestAppDatabase();
    await _account(db, 'change', 'CNY', 10025);
    await pumpPage(tester, const AccountsPage(), db: db);
    await settleProviders(tester);
    await _edit(tester, '账户change');
    await _choose(tester, 'JPY · 日元');
    final field = find.widgetWithText(TextField, '期初余额（JPY）');
    expect(tester.widget<TextField>(field).controller!.text, '100.25');
    await _save(tester, closes: false);
    expect(find.text('日元期初余额须为整数，且在支持范围内'), findsOneWidget);
    final unchanged = (await db.getAccount('change'))!;
    expect(unchanged.currency, 'CNY');
    expect(unchanged.initBalance, 10025);
    await tester.enterText(field, '100');
    await _save(tester);
    final changed = (await db.getAccount('change'))!;
    expect(changed.currency, 'JPY');
    expect(changed.initBalance, 100);
    expect(find.text('JPY 100'), findsOneWidget);
    await disposePage(tester, db);
  });

  for (final incoming in [false, true]) {
    testWidgets('${incoming ? '仅转入' : '软删除'}引用锁币种并阻止删除，仍可修改名称', (tester) async {
      final db = TestAppDatabase();
      await _account(db, 'referenced', 'CNY', 10000);
      await db.upsertBill(
        id: 'reference',
        type: incoming ? 2 : 0,
        amount: 100,
        accountId: incoming ? 'acc_cash' : 'referenced',
        toAccountId: incoming ? 'referenced' : null,
        dateMs: 1,
      );
      if (!incoming) await db.softDeleteBill('reference');
      await pumpPage(tester, const AccountsPage(), db: db);
      await settleProviders(tester);
      await _edit(tester, '账户referenced');
      final dropdown = tester.widget<DropdownButtonFormField<Currency>>(
        find.byKey(const ValueKey('account_currency')),
      );
      expect(dropdown.onChanged, isNull);
      expect(find.text('已有账单引用（含已删除），币种不可修改'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await settleProviders(tester);
      expect(find.textContaining('已有 1 笔账单，无法删除'), findsOneWidget);
      expect(await db.getAccount('referenced'), isNotNull);
      await tester.enterText(find.widgetWithText(TextField, '名称'), '引用账户改名');
      await _save(tester);
      final saved = (await db.getAccount('referenced'))!;
      expect(saved.name, '引用账户改名');
      expect(saved.currency, 'CNY');
      expect(saved.initBalance, 10000);
      await disposePage(tester, db);
    });
  }

  testWidgets('AA固定账户只显示锁定CNY，不提供删除', (tester) async {
    final db = TestAppDatabase();
    await db.upsertAccount(
      id: kAaCreditAccountId,
      name: 'AA挂账',
      emoji: '🤝',
      type: 4,
      initBalance: 0,
      includeNetWorth: false,
      sort: 99,
    );
    await pumpPage(tester, const AccountsPage(), db: db);
    await settleProviders(tester);
    await _edit(tester, 'AA挂账');
    expect(
      tester
          .widget<DropdownButtonFormField<Currency>>(
            find.byKey(const ValueKey('account_currency')),
          )
          .onChanged,
      isNull,
    );
    expect(find.text('AA挂账固定使用 CNY'), findsOneWidget);
    expect(find.text('删除'), findsNothing);
    expect((await db.getAccount(kAaCreditAccountId))!.currency, 'CNY');
    await disposePage(tester, db);
  });

  testWidgets('账户旧编辑窗口不能覆盖别处已改的币种及期初额', (tester) async {
    final db = TestAppDatabase();
    await _account(db, 'stale', 'CNY', 10000);
    await pumpPage(tester, const AccountsPage(), db: db);
    await settleProviders(tester);
    await _edit(tester, '账户stale');
    await tester.runAsync(() => _account(db, 'stale', 'JPY', 777));
    await settleProviders(tester);
    await tester.enterText(find.widgetWithText(TextField, '名称'), '旧窗口修改');
    await _save(tester, closes: false);
    expect(find.textContaining('账户已变化，请关闭后重新打开'), findsOneWidget);
    final saved = (await db.getAccount('stale'))!;
    expect(saved.name, '账户stale');
    expect(saved.currency, 'JPY');
    expect(saved.initBalance, 777);
    await disposePage(tester, db);
  });

  testWidgets('期初余额超出int64不保存为零，完整金额与错误留在窗口', (tester) async {
    final db = await pumpPage(tester, const AccountsPage());
    await tester.tap(find.byTooltip('添加账户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名称'), '超限账户');
    await tester.enterText(
      find.widgetWithText(TextField, '期初余额（元）'),
      '92233720368547758.08',
    );
    await _save(tester, closes: false);
    expect(find.text('请输入有效期初余额，最多两位小数且在支持范围内'), findsOneWidget);
    expect((await db.getAllAccounts()).any((a) => a.name == '超限账户'), isFalse);
    await disposePage(tester, db);
  });
}
