import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/transfer_fee.dart';

import '../helpers/test_support.dart';

Future<Bill> _parent(AppDatabase db) => (db.select(
  db.bills,
)..where((row) => row.id.equals('detail-transfer'))).getSingle();

Future<({Bill parent, Bill? fee})> _seed(
  AppDatabase db, {
  int amount = 10000,
  int incoming = 10000,
  int feeAmount = 125,
  bool cancelled = false,
  String? sourceCurrency,
  String? targetCurrency,
}) async {
  await db.getAllAccounts();
  Future<void> account(String id, String currency) => db.upsertAccount(
    id: id,
    name: id,
    emoji: '💳',
    type: 3,
    initBalance: 0,
    includeNetWorth: true,
    sort: 20,
    currency: currency,
  );
  final source = sourceCurrency == null ? 'acc_cash' : 'detail-source';
  final target = targetCurrency == null ? 'acc_bank' : 'detail-target';
  if (sourceCurrency != null) await account(source, sourceCurrency);
  if (targetCurrency != null) await account(target, targetCurrency);
  final now = DateTime.now();
  final date = DateTime(now.year, now.month, 9, 12).millisecondsSinceEpoch;
  await db.saveTransferWithFee(
    id: 'detail-transfer',
    amount: amount,
    toAccountAmount: incoming,
    dateMs: date,
    note: '统一转账详情',
    feeAmount: feeAmount,
    feeCategoryId: 'cat_food',
    expectedSource: (await db.getAccount(source))!,
    expectedTarget: (await db.getAccount(target))!,
  );
  if (cancelled) {
    await db.saveTransferWithFee(
      id: 'detail-transfer',
      amount: amount,
      toAccountAmount: incoming,
      dateMs: date,
      note: '统一转账详情',
      feeAmount: 0,
      expectedSource: (await db.getAccount(source))!,
      expectedTarget: (await db.getAccount(target))!,
      expectedTransfer: await _parent(db),
      expectedFee: await db.getTransferFee('detail-transfer'),
    );
  }
  return (
    parent: await _parent(db),
    fee: await db.getTransferFee('detail-transfer'),
  );
}

Finder _detailText(String value) => find.descendant(
  of: find.byType(BillDetailPage),
  matching: find.text(value),
);

/// Bound asynchronous database/UI work without waiting for a long timeout.
Future<void> _tapAndWait(
  WidgetTester tester,
  Finder finder,
  Future<bool> Function() done,
) async {
  var finished = false;
  // Pointer events and SnackBar animations belong to the test clock. Only
  // database polling runs on the real event loop.
  await tester.tap(finder);
  await tester.runAsync(() async {
    for (var i = 0; i < 50; i++) {
      if (await done()) {
        finished = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
  await settleProviders(tester);
  expect(finished, isTrue);
}

Future<void> _delete(WidgetTester tester, AppDatabase db) async {
  await tester.drag(find.text('转账'), const Offset(-120, 0));
  await settleProviders(tester);
  await _tapAndWait(
    tester,
    find.byTooltip('删除').hitTestable(),
    () async => (await _parent(db)).deletedAt != null,
  );
}

Future<void> _waitForSnack(WidgetTester tester, String message) async {
  for (var i = 0; i < 20 && find.text(message).evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await settleProviders(tester);
  expect(find.text(message), findsOneWidget);
}

Future<void> _closeSnacks(WidgetTester tester) async {
  final context = tester.element(find.byType(BillsPage));
  ScaffoldMessenger.of(context).clearSnackBars();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await settleProviders(tester);
  expect(find.byType(SnackBar), findsNothing);
}

void main() {
  test('统一维护校验拒绝异常关联、未知币种和缺账户，允许保留取消费用的旧日期', () {
    final parent = mkBill(
      'parent',
      type: 2,
      amount: 1000,
      accountId: 'source',
      toAccountId: 'target',
      toAccountAmount: 1000,
    );
    final fee = mkBill(
      'fee',
      amount: 25,
      accountId: 'source',
    ).copyWith(feeTransferId: const Value('parent'));
    final accounts = {
      'source': mkAccount('source'),
      'target': mkAccount('target'),
    };
    expect(canManageTransferFee(parent, fee, accounts), isTrue);
    expect(canManageTransferFee(parent, null, accounts), isTrue);
    expect(
      canManageTransferFee(
        parent,
        fee.copyWith(
          accountId: 'old-source',
          dateMs: 100,
          deletedAt: const Value(1),
        ),
        accounts,
      ),
      isTrue,
    );
    for (final abnormal in [
      parent.copyWith(type: 0),
      parent.copyWith(
        amount: -1,
        accountAmount: -1,
        toAccountAmount: const Value(-1),
      ),
      parent.copyWith(accountAmount: 999),
      parent.copyWith(toAccountId: const Value('source')),
      parent.copyWith(toAccountAmount: const Value(999)),
      parent.copyWith(currency: 'cny'),
      parent.copyWith(isAa: true),
      parent.copyWith(aaGroupId: const Value('group')),
      parent.copyWith(settlementId: const Value('settlement')),
      parent.copyWith(deletedAt: const Value(1)),
      parent.copyWith(feeTransferId: const Value('other-parent')),
      parent.copyWith(feeDeletedWithTransferAt: const Value(1)),
    ]) {
      expect(canManageTransferFee(abnormal, fee, accounts), isFalse);
    }
    for (final abnormal in [
      fee.copyWith(type: 1),
      fee.copyWith(amount: 0, accountAmount: 0),
      fee.copyWith(accountAmount: 20),
      fee.copyWith(currency: 'XYZ'),
      fee.copyWith(feeTransferId: const Value('other-parent')),
      fee.copyWith(
        feeDeletedWithTransferAt: const Value(1),
        deletedAt: const Value(1),
      ),
      fee.copyWith(accountId: 'other-source'),
      fee.copyWith(dateMs: 1),
      fee.copyWith(toAccountId: const Value('target')),
      fee.copyWith(toAccountAmount: const Value(25)),
      fee.copyWith(isAa: true),
      fee.copyWith(aaGroupId: const Value('group')),
      fee.copyWith(settlementId: const Value('settlement')),
    ]) {
      expect(canManageTransferFee(parent, abnormal, accounts), isFalse);
    }
    expect(
      canManageTransferFee(parent, fee, {'source': accounts['source']!}),
      isFalse,
    );
    expect(
      canManageTransferFee(parent, fee, {
        ...accounts,
        'target': mkAccount('target', type: 4),
      }),
      isFalse,
    );
    expect(
      canManageTransferFee(parent, fee, {
        ...accounts,
        'target': mkAccount('target', currency: 'XYZ'),
      }),
      isFalse,
    );
    final legacy = parent.copyWith(toAccountAmount: const Value(null));
    expect(canManageTransferFee(legacy, null, accounts), isTrue);
    expect(canManageTransferFee(legacy, fee, accounts), isFalse);
  });

  testWidgets('跨币种转账详情保留双方原金额，手续费与总扣款使用出账币种', (tester) async {
    final db = TestAppDatabase();
    final fixture = await _seed(
      db,
      sourceCurrency: 'USD',
      targetCurrency: 'JPY',
      amount: 12345,
      incoming: 15000,
      feeAmount: 123,
    );
    await pumpPage(tester, BillDetailPage(bill: fixture.parent), db: db);
    expect(_detailText('USD 123.45'), findsWidgets);
    expect(_detailText('JPY 15,000'), findsOneWidget);
    expect(_detailText('USD 1.23'), findsOneWidget);
    expect(_detailText('USD 124.68'), findsOneWidget);
    expect(_detailText('修改').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('无费用与已取消费用明确显示零，总扣款只等于本金', (tester) async {
    for (final cancelled in [false, true]) {
      final db = TestAppDatabase();
      final fixture = await _seed(
        db,
        feeAmount: cancelled ? 125 : 0,
        cancelled: cancelled,
      );
      await pumpPage(tester, BillDetailPage(bill: fixture.parent), db: db);
      expect(_detailText(cancelled ? '¥ 0.00（已取消）' : '¥ 0.00'), findsOneWidget);
      expect(_detailText('¥ 100.00'), findsNWidgets(4));
      expect(_detailText('修改').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }
  });

  testWidgets('总扣款超过单条账单的 64 位范围时仍精确展示且不溢出', (tester) async {
    const maximum = 9223372036854775807;
    final db = TestAppDatabase();
    final fixture = await _seed(
      db,
      amount: maximum,
      incoming: maximum,
      feeAmount: maximum,
    );
    await pumpPage(tester, BillDetailPage(bill: fixture.parent), db: db);
    expect(_detailText('¥ 184,467,440,737,095,516.14'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('真实滑删与撤销同时维护父转账和活动费用，取消历史不会重新恢复', (tester) async {
    for (final cancelled in [false, true]) {
      final db = TestAppDatabase();
      final fixture = await _seed(db, cancelled: cancelled);
      await pumpPage(tester, const BillsPage(), db: db);
      await _delete(tester, db);
      final deletedParent = await _parent(db);
      final deletedFee = (await db.getTransferFee(fixture.parent.id))!;
      expect(deletedParent.deletedAt, isNotNull);
      if (cancelled) {
        expect(deletedFee, fixture.fee);
        expect(deletedFee.feeDeletedWithTransferAt, isNull);
      } else {
        expect(deletedFee.deletedAt, deletedParent.deletedAt);
        expect(deletedFee.feeDeletedWithTransferAt, deletedParent.deletedAt);
      }
      expect(await db.getAllBills(), isEmpty);
      await _tapAndWait(
        tester,
        find.text('撤销'),
        () async => (await _parent(db)).deletedAt == null,
      );
      final restoredParent = await _parent(db);
      final restoredFee = (await db.getTransferFee(fixture.parent.id))!;
      expect(
        restoredParent.copyWith(updatedAt: fixture.parent.updatedAt),
        fixture.parent,
      );
      expect(
        restoredFee.copyWith(updatedAt: fixture.fee!.updatedAt),
        fixture.fee,
      );
      expect(restoredFee.feeDeletedWithTransferAt, isNull);
      expect((await db.getAllBills()).length, cancelled ? 1 : 2);
      await _closeSnacks(tester);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }
  });

  testWidgets('滑删使用已展示费用的完整快照，费用被另行变更时拒绝删除', (tester) async {
    final db = TestAppDatabase();
    final fixture = await _seed(db);
    await pumpPage(
      tester,
      const BillsPage(),
      db: db,
      overrides: [
        transferFeeProvider(fixture.parent.id)
            .overrideWith((ref) => Stream.value(fixture.fee)),
      ],
    );
    await (db.update(db.bills)..where((row) => row.id.equals(fixture.fee!.id)))
        .write(const BillsCompanion(note: Value('外部已修改')));
    await settleProviders(tester);
    final before = await db.select(db.bills).get();
    await tester.drag(find.text('转账'), const Offset(-120, 0));
    await settleProviders(tester);
    await tester.tap(find.byTooltip('删除').hitTestable());
    await _waitForSnack(tester, '转账或手续费已变更，请返回后重试');
    expect(await db.select(db.bills).get(), before);
    await _closeSnacks(tester);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('撤销使用本次删除后的双行完整快照，已变更删除记录保持原状并提示错误', (tester) async {
    final db = TestAppDatabase();
    final fixture = await _seed(db);
    await pumpPage(tester, const BillsPage(), db: db);
    await _delete(tester, db);
    await (db.update(db.bills)..where((row) => row.id.equals(fixture.fee!.id)))
        .write(const BillsCompanion(note: Value('删除后外部修改')));
    final before = await db.select(db.bills).get();
    await tester.tap(find.text('撤销'));
    await _waitForSnack(tester, '转账或手续费已变更，请返回后重试');
    expect(await db.select(db.bills).get(), before);
    expect((await _parent(db)).deletedAt, isNotNull);
    await _closeSnacks(tester);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
