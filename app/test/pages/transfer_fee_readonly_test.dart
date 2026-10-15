import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';

import '../helpers/test_support.dart';

const _lockedMessage = '手续费需随转账统一修改';

Finder _detailText(String text) =>
    find.descendant(of: find.byType(BillDetailPage), matching: find.text(text));

Future<({Bill transfer, Bill? fee})> _seed(
  TestAppDatabase db, {
  bool? cancelled,
}) async {
  await db.getAllAccounts();
  final now = DateTime.now();
  final date = DateTime(now.year, now.month, 8, 12).millisecondsSinceEpoch;
  await db.upsertBill(
    id: 'fee-parent',
    type: 2,
    amount: 10000,
    accountAmount: 10000,
    toAccountAmount: 10000,
    accountId: 'acc_cash',
    toAccountId: 'acc_bank',
    dateMs: date,
    note: '本金金额保留',
  );
  if (cancelled != null) {
    // 隔离页面保护测试的夹具；事务与写入约束由 DAO 专项另行验证。
    await db
        .into(db.bills)
        .insert(
          BillsCompanion.insert(
            id: 'fee-child',
            type: 0,
            amount: 125,
            accountAmount: const Value(125),
            accountId: 'acc_cash',
            categoryId: const Value('cat_food'),
            dateMs: date,
            note: const Value('关联手续费'),
            createdAt: 1,
            updatedAt: 1,
            feeTransferId: const Value('fee-parent'),
            deletedAt: Value(cancelled ? 2 : null),
          ),
        );
  }
  final rows = await db.select(db.bills).get();
  return (
    transfer: rows.singleWhere((row) => row.id == 'fee-parent'),
    fee: rows.where((row) => row.id == 'fee-child').firstOrNull,
  );
}

Future<void> _openDetail(WidgetTester tester, String title) async {
  await tester.tap(find.widgetWithText(ListTile, title));
  await settleProviders(tester);
  expect(find.byType(BillDetailPage), findsOneWidget);
}

Future<void> _closeDetail(WidgetTester tester) async {
  await tester.tap(find.byTooltip('关闭详情'));
  await settleProviders(tester);
}

Future<void> _directEdit(WidgetTester tester, Bill bill) async {
  final context = tester.element(find.byType(BillsPage));
  unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => EditBillPage(bill: bill)),
    ),
  );
  await settleProviders(tester);
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await settleProviders(tester);
}

void _expectNoEditor() {
  expect(find.byType(NumberPad), findsNothing);
  expect(find.text('保存'), findsNothing);
}

void main() {
  testWidgets('手续费子账可看原金额，详情与直接编辑只读且没有滑删入口', (tester) async {
    final db = TestAppDatabase();
    final fixture = await _seed(db, cancelled: false);
    final before = await db.select(db.bills).get();
    await pumpPage(tester, const BillsPage(), db: db);

    await tester.drag(find.text('关联手续费'), const Offset(-120, 0));
    await settleProviders(tester);
    expect(find.byTooltip('删除').hitTestable(), findsNothing);
    await _openDetail(tester, '关联手续费');
    expect(_detailText('-¥ 1.25'), findsOneWidget);
    expect(_detailText('修改'), findsNothing);
    expect(_detailText(_lockedMessage), findsOneWidget);
    await _closeDetail(tester);

    await _directEdit(tester, fixture.fee!);
    expect(find.text(_lockedMessage), findsOneWidget);
    _expectNoEditor();
    expect(await db.select(db.bills).get(), before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('父转账有活动或已取消手续费历史可统一编辑，保留本金详情与滑删入口', (tester) async {
    for (final cancelled in [false, true]) {
      final db = TestAppDatabase();
      final fixture = await _seed(db, cancelled: cancelled);
      final before = await db.select(db.bills).get();
      await pumpPage(tester, const BillsPage(), db: db);
      if (cancelled) {
        expect(find.text('关联手续费'), findsNothing);
      }
      await _openDetail(tester, '转账');
      expect(_detailText('¥ 100.00'), findsWidgets);
      expect(_detailText('转出金额'), findsOneWidget);
      expect(_detailText('转入金额'), findsOneWidget);
      expect(_detailText('修改').hitTestable(), findsOneWidget);
      expect(_detailText('手续费'), findsOneWidget);
      expect(_detailText('总扣款'), findsOneWidget);
      expect(_detailText(_lockedMessage), findsNothing);
      await _closeDetail(tester);

      await _directEdit(tester, fixture.transfer);
      expect(find.text(_lockedMessage), findsNothing);
      expect(find.byType(NumberPad), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      await _back(tester);
      await tester.drag(find.text('转账'), const Offset(-120, 0));
      await settleProviders(tester);
      expect(find.byTooltip('删除').hitTestable(), findsOneWidget);
      expect(await db.select(db.bills).get(), before);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }
  });

  testWidgets('查询确认无手续费的普通转账保留修改与滑删入口', (tester) async {
    final db = TestAppDatabase();
    await _seed(db);
    await pumpPage(tester, const BillsPage(), db: db);
    await _openDetail(tester, '转账');
    expect(_detailText('¥ 100.00'), findsWidgets);
    expect(_detailText('修改').hitTestable(), findsOneWidget);
    await tester.tap(_detailText('修改'));
    await settleProviders(tester);
    expect(find.byType(NumberPad), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text(_lockedMessage), findsNothing);
    await _back(tester);
    await _closeDetail(tester);

    await tester.drag(find.text('转账'), const Offset(-120, 0));
    await settleProviders(tester);
    expect(find.byTooltip('删除').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('仅有费用删除标记的异常旧账也禁止编辑与滑删，金额仍可查看', (tester) async {
    final db = TestAppDatabase();
    final fixture = await _seed(db);
    // 模拟异常旧数据，不能因缺失 owner 而把残留费用标记当作普通转账。
    await (db.update(db.bills)
          ..where((row) => row.id.equals(fixture.transfer.id)))
        .write(const BillsCompanion(feeDeletedWithTransferAt: Value(7)));
    final bill = await db.select(db.bills).getSingle();
    expect(bill.feeTransferId, isNull);
    final before = await db.select(db.bills).get();
    await pumpPage(tester, const BillsPage(), db: db);
    await tester.drag(find.text('转账'), const Offset(-120, 0));
    await settleProviders(tester);
    expect(find.byTooltip('删除'), findsNothing);
    await _openDetail(tester, '转账');
    expect(_detailText('¥ 100.00'), findsWidgets);
    expect(_detailText('修改'), findsNothing);
    expect(_detailText(_lockedMessage), findsOneWidget);
    await _closeDetail(tester);
    await _directEdit(tester, bill);
    expect(find.text(_lockedMessage), findsOneWidget);
    _expectNoEditor();
    expect(await db.select(db.bills).get(), before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('手续费查询等待、错误和保留旧空值重载时均不开放修改或滑删', (tester) async {
    final db = TestAppDatabase();
    final fixture = await _seed(db);
    final fees = StreamController<Bill?>.broadcast();
    addTearDown(fees.close);
    await pumpPage(
      tester,
      const BillsPage(),
      db: db,
      overrides: [
        transferFeeProvider(fixture.transfer.id)
            .overrideWith((ref) => fees.stream),
      ],
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BillsPage)),
    );

    Future<void> expectProtected(String message) async {
      expect(find.byTooltip('删除'), findsNothing);
      await _openDetail(tester, '转账');
      expect(_detailText('¥ 100.00'), findsWidgets);
      expect(_detailText('修改'), findsNothing);
      await _closeDetail(tester);
      await _directEdit(tester, fixture.transfer);
      expect(find.text(message), findsOneWidget);
      _expectNoEditor();
      await _back(tester);
    }

    await expectProtected('正在读取手续费关联，请稍后重试');
    fees.addError(StateError('费用查询失败'));
    await settleProviders(tester);
    await expectProtected('手续费关联读取失败，请返回后重试');

    fees.add(null);
    await settleProviders(tester);
    expect(find.byTooltip('删除'), findsOneWidget);
    container.invalidate(transferFeeProvider(fixture.transfer.id));
    await settleProviders(tester);
    final reloading = container.read(transferFeeProvider(fixture.transfer.id));
    expect(reloading.isLoading, isTrue);
    expect(reloading.hasValue, isTrue);
    expect(reloading.value, isNull);
    await expectProtected('正在读取手续费关联，请稍后重试');
    fees.add(null);
    await settleProviders(tester);
    expect(find.byTooltip('删除'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
