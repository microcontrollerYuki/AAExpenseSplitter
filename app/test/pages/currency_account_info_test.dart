import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/account_info_page.dart';

import '../helpers/test_support.dart';

Future<Account> _account(
  AppDatabase db,
  String id,
  String currency, {
  int balance = 0,
}) async {
  await db.upsertAccount(
    id: id,
    name: '旅行钱包',
    emoji: '💳',
    type: 3,
    initBalance: balance,
    includeNetWorth: true,
    sort: 20,
    currency: currency,
  );
  return (await db.getAccount(id))!;
}

Future<void> _bill(
  AppDatabase db,
  String id, {
  required String accountId,
  required int amount,
  String currency = 'CNY',
  int? actual,
  int type = 0,
  String? toAccountId,
  int? dateMs,
  String note = '',
}) => db.upsertBill(
  id: id,
  type: type,
  accountId: accountId,
  toAccountId: toAccountId,
  amount: amount,
  accountAmount: actual,
  currency: currency,
  dateMs: dateMs ?? DateTime(2026, 10, 11, 12).millisecondsSinceEpoch,
  note: note,
);

void main() {
  testWidgets('人民币账户余额动账及月流入流出显示跨币实际额', (tester) async {
    final db = TestAppDatabase();
    final account = await _account(db, 'cash', 'CNY', balance: 10000);
    await _bill(
      db,
      'expense',
      accountId: 'cash',
      amount: 1000,
      currency: 'USD',
      actual: 7200,
      note: '美元消费',
    );
    await _bill(
      db,
      'income',
      accountId: 'cash',
      amount: 200,
      currency: 'USD',
      actual: 1440,
      type: 1,
      note: '美元收入',
    );
    await _bill(db, 'deleted', accountId: 'cash', amount: 999, note: '已删除不展示');
    await db.softDeleteBill('deleted');

    await pumpPage(tester, AccountInfoPage(account: account), db: db);

    expect(find.text('账户余额'), findsOneWidget);
    expect(find.text('CNY'), findsOneWidget);
    expect(find.text('¥ 42.40'), findsOneWidget);
    expect(find.text('-72.00'), findsOneWidget);
    expect(find.text('+14.40'), findsOneWidget);
    expect(find.text('流入:¥ 14.40'), findsOneWidget);
    expect(find.text('流出:¥ 72.00'), findsOneWidget);
    expect(find.text('已删除不展示'), findsNothing);
    expect(find.text('-10.00'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('日元整数动账包含跨币实际额同币转账及有符号调节', (tester) async {
    final db = TestAppDatabase();
    final account = await _account(db, 'jpy', 'JPY', balance: 5000);
    await _account(db, 'other-jpy', 'JPY');
    await _bill(
      db,
      'expense',
      accountId: 'jpy',
      amount: 1000,
      currency: 'USD',
      actual: 1531,
      note: '美元消费',
    );
    await _bill(
      db,
      'out',
      accountId: 'jpy',
      toAccountId: 'other-jpy',
      type: 2,
      currency: 'JPY',
      amount: 500,
    );
    await _bill(
      db,
      'in',
      accountId: 'other-jpy',
      toAccountId: 'jpy',
      type: 2,
      currency: 'JPY',
      amount: 300,
    );
    await _bill(
      db,
      'minus',
      accountId: 'jpy',
      type: 3,
      currency: 'JPY',
      amount: -200,
    );
    await _bill(
      db,
      'plus',
      accountId: 'jpy',
      type: 3,
      currency: 'JPY',
      amount: 100,
    );
    await _bill(
      db,
      'income',
      accountId: 'jpy',
      type: 1,
      currency: 'JPY',
      amount: 500,
    );
    await _bill(
      db,
      'previous-month',
      accountId: 'jpy',
      amount: 0,
      currency: 'JPY',
      dateMs: DateTime(2026, 9, 30).millisecondsSinceEpoch,
    );

    await pumpPage(tester, AccountInfoPage(account: account), db: db);

    expect(find.text('JPY 3,669'), findsOneWidget);
    expect(find.text('JPY -1,531'), findsOneWidget);
    expect(find.text('JPY -500'), findsOneWidget);
    expect(find.text('JPY +300'), findsOneWidget);
    expect(find.text('JPY -200'), findsOneWidget);
    expect(find.text('流入:JPY 900'), findsOneWidget);
    expect(find.text('流出:JPY 2,231'), findsOneWidget);
    expect(find.textContaining('.00'), findsNothing);
    expect(
      tester.getTopLeft(find.text('2026年10月')).dy,
      lessThan(tester.getTopLeft(find.text('2026年09月')).dy),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('账户币种更新后使用数据库最新账户而非页面初始快照', (tester) async {
    final db = TestAppDatabase();
    final snapshot = await _account(db, 'wallet', 'CNY', balance: 1000);
    await pumpPage(tester, AccountInfoPage(account: snapshot), db: db);
    expect(find.text('¥ 10.00'), findsOneWidget);

    await _account(db, 'wallet', 'JPY', balance: 1000);
    await settleProviders(tester);

    expect(find.text('JPY 1,000'), findsOneWidget);
    expect(find.text('¥ 10.00'), findsNothing);
    expect(snapshot.currency, 'CNY');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('最小调节再支出一分后余额及月流出仍精确，不因聚合或取反溢出', (tester) async {
    final db = TestAppDatabase();
    final account = await _account(db, 'cash', 'CNY');
    await _bill(
      db,
      'minimum',
      accountId: 'cash',
      type: 3,
      amount: -9223372036854775808,
    );
    await _bill(db, 'one-more', accountId: 'cash', amount: 1);

    await pumpPage(tester, AccountInfoPage(account: account), db: db);

    expect(find.text('¥ -92,233,720,368,547,758.09'), findsOneWidget);
    expect(find.text('-92,233,720,368,547,758.08'), findsOneWidget);
    expect(find.text('-0.01'), findsOneWidget);
    expect(find.text('流出:¥ 92,233,720,368,547,758.09'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('两笔合法收入超过 int64 后账户余额及月流入显示精确正数', (tester) async {
    final db = TestAppDatabase();
    final account = await _account(db, 'cash', 'CNY');
    await _bill(
      db,
      'maximum',
      accountId: 'cash',
      type: 1,
      amount: 9223372036854775807,
    );
    await _bill(db, 'one-more', accountId: 'cash', type: 1, amount: 1);

    await pumpPage(tester, AccountInfoPage(account: account), db: db);

    expect(find.text('¥ 92,233,720,368,547,758.08'), findsOneWidget);
    expect(find.text('流入:¥ 92,233,720,368,547,758.08'), findsOneWidget);
    expect(find.text('+92,233,720,368,547,758.07'), findsOneWidget);
    expect(find.text('+0.01'), findsOneWidget);
    expect(find.text('流出:¥ 0.00'), findsOneWidget);
    expect(find.textContaining('-92,233'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('未知历史账户币种展示原代码和整数最小单位，不默认人民币', (tester) async {
    final db = TestAppDatabase();
    final snapshot = await _account(db, 'wallet', 'CNY', balance: 12345);
    // DAO 已拒绝未知代码；以原始行模拟历史坏数据，验证只读展示兜底。
    await db.customStatement('UPDATE accounts SET currency = ? WHERE id = ?', [
      'XTS',
      'wallet',
    ]);
    await pumpPage(tester, AccountInfoPage(account: snapshot), db: db);

    expect(find.text('XTS'), findsOneWidget);
    expect(find.text('XTS 12345 最小单位'), findsOneWidget);
    expect(find.textContaining('¥'), findsNothing);
    expect(find.textContaining('123.45'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('窄屏大字体账户余额月摘要及大额动账完整显示无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = TestAppDatabase();
    final account = await _account(db, 'jpy', 'JPY');
    await _bill(
      db,
      'large',
      accountId: 'jpy',
      type: 1,
      currency: 'JPY',
      amount: 9007199254740993,
      note: '很长的收入备注' * 10,
    );

    await pumpPage(tester, AccountInfoPage(account: account), db: db);

    final balance = find.text('JPY 9,007,199,254,740,993');
    expect(balance, findsOneWidget);
    expect(tester.getRect(balance).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(balance).right, lessThanOrEqualTo(320));
    final rowAmount = find.text('JPY +9,007,199,254,740,993');
    await tester.ensureVisible(rowAmount);
    await settleProviders(tester);
    expect(tester.getRect(rowAmount).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(rowAmount).right, lessThanOrEqualTo(320));
    expect(find.text('流入:JPY 9,007,199,254,740,993'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
