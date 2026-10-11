import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/account_info_page.dart';

import '../helpers/test_support.dart';

Future<Account> _account(
  AppDatabase db,
  String id,
  String currency,
  int opening,
) async {
  await db.upsertAccount(
    id: id,
    name: id,
    emoji: '💳',
    type: 3,
    initBalance: opening,
    includeNetWorth: true,
    sort: 20,
    currency: currency,
  );
  return (await db.getAccount(id))!;
}

void main() {
  testWidgets('跨币转账双方详情各用自身币种金额，余额与月动账一致', (tester) async {
    final db = TestAppDatabase();
    final cash = await _account(db, 'source', 'CNY', 100000);
    final usd = await _account(db, 'target', 'USD', 0);
    await db.upsertBill(
      id: 'transfer',
      type: 2,
      amount: 72000,
      currency: 'CNY',
      accountId: cash.id,
      toAccountId: usd.id,
      toAccountAmount: 10000,
      dateMs: DateTime(2026, 10, 11, 12).millisecondsSinceEpoch,
    );
    await pumpPage(tester, AccountInfoPage(account: cash), db: db);
    expect(find.text('¥ 280.00'), findsOneWidget);
    expect(find.text('流出:¥ 720.00'), findsOneWidget);
    expect(find.text('-720.00'), findsOneWidget);
    expect(find.text('转出'), findsOneWidget);

    await pumpPage(tester, AccountInfoPage(account: usd), db: db);
    expect(find.text('USD 100.00'), findsOneWidget);
    expect(find.text('流入:USD 100.00'), findsOneWidget);
    expect(find.text('USD +100.00'), findsOneWidget);
    expect(find.text('转入'), findsOneWidget);
    expect(find.text('USD 720.00'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('美元转入日元保持整数，软删除与恢复实时刷新入账余额', (tester) async {
    final db = TestAppDatabase();
    final usd = await _account(db, 'source', 'USD', 2000);
    final jpy = await _account(db, 'target', 'JPY', 100);
    await db.upsertBill(
      id: 'transfer',
      type: 2,
      amount: 1000,
      currency: 'USD',
      accountId: usd.id,
      toAccountId: jpy.id,
      toAccountAmount: 1500,
      dateMs: DateTime(2026, 10, 11, 12).millisecondsSinceEpoch,
    );
    await pumpPage(tester, AccountInfoPage(account: jpy), db: db);
    expect(find.text('JPY 1,600'), findsOneWidget);
    expect(find.text('流入:JPY 1,500'), findsOneWidget);
    expect(find.text('JPY +1,500'), findsOneWidget);

    await db.softDeleteBill('transfer');
    await settleProviders(tester);
    expect(find.text('JPY 100'), findsOneWidget);
    expect(find.text('该账户还没有动账记录'), findsOneWidget);
    await db.restoreBill('transfer');
    await settleProviders(tester);
    expect(find.text('JPY 1,600'), findsOneWidget);
    expect(find.text('JPY +1,500'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
