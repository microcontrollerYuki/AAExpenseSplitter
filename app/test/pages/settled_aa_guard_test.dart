import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';

import '../helpers/test_support.dart';

const _groupId = 'original-aa-group';
const _settlementId = 'completed-settlement';

class _DelayedSimilarBillsDatabase extends TestAppDatabase {
  final lookupEntered = Completer<void>();
  final releaseLookup = Completer<void>();

  @override
  Future<List<Bill>> findSimilarBills({
    required int type,
    required int amount,
    required int dateMs,
    String? excludeId,
  }) async {
    lookupEntered.complete();
    await releaseLookup.future;
    // 本用例只需要控制查重完成的时机，不再启动无关的 Drift 查询。
    return const [];
  }
}

Future<void> _drainSave(
  WidgetTester tester,
  bool Function() completed,
) async {
  // 保存会触发真实数据库 Future 和假时钟中的 Provider/路由微任务，
  // 只在 runAsync 里 await 会饿死后者；交替排空，两秒内结束。
  for (var attempt = 0; attempt < 40 && !completed(); attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
}

Future<Bill> _seedOriginalAa(
  TestAppDatabase db, {
  required bool ownerView,
  bool settled = true,
}) async {
  await db.getAllAccounts();
  await db.setMeta('myUid', 'local-uid');
  await db.setMeta('partnerUid', 'partner-uid');
  await db.setMeta('pairSecret', 'guard-secret');
  final ownerUid = ownerView ? 'local-uid' : 'partner-uid';
  final dateMs = DateTime(2026, 10, 3, 14, 25).millisecondsSinceEpoch;
  await db.upsertAaGroup(AaGroupsCompanion.insert(
    id: _groupId,
    ownerUid: ownerUid,
    payerUid: ownerUid,
    totalAmount: 2468,
    dateMs: dateMs,
    note: const Value('原始 AA 备注'),
    categoryName: const Value('餐饮'),
    categoryEmoji: const Value('🍜'),
    status: const Value(1),
    createdAtMs: 1,
    updatedAtMs: 10,
  ));
  await db.upsertBill(
    id: 'original-aa-bill',
    type: 0,
    amount: ownerView ? 2468 : 1234,
    categoryId: 'cat_food',
    accountId: 'acc_cash',
    dateMs: dateMs,
    note: '原始 AA 备注',
    aaGroupId: _groupId,
    createdAt: 123456,
  );
  if (settled) await _completeSettlement(db);
  final bill = (await db.getAllBills()).single;
  expect(bill.aaGroupId, _groupId);
  expect(bill.settlementId, isNull);
  return bill;
}

Future<void> _completeSettlement(TestAppDatabase db) => db.transaction(() async {
      final payerUid = (await db.getAaGroup(_groupId))!.payerUid;
      await db.upsertSettlement(SettlementsCompanion.insert(
        id: _settlementId,
        receiverUid: payerUid,
        amount: 1234,
        dateMs: 30,
        cutoffMs: 30,
        createdAtMs: 30,
      ));
      await db.markGroupsSettled([_groupId], _settlementId, 50);
    });

Future<Map<String, Object?>> _snapshot(TestAppDatabase db) async => {
      'bills': {
        for (final bill in await db.select(db.bills).get())
          bill.id: bill.toJson(),
      },
      'groups': {
        for (final group in await db.getAllAaGroups())
          group.id: group.toJson(),
      },
      'settlements': {
        for (final settlement in await db.getAllSettlements())
          settlement.id: settlement.toJson(),
      },
    };

Future<Bill> _seedOrdinaryBill(TestAppDatabase db) async {
  await db.getAllAccounts();
  await db.upsertBill(
    id: 'ordinary-before-settlement',
    type: 0,
    amount: 2468,
    categoryId: 'cat_food',
    accountId: 'acc_cash',
    dateMs: DateTime(2026, 10, 3, 14, 25).millisecondsSinceEpoch,
    note: '普通账单陈旧删除入口',
  );
  return (await db.getAllBills()).single;
}

Future<void> _convertAndSettle(TestAppDatabase db, Bill bill) =>
    db.transaction(() async {
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: _groupId,
        ownerUid: 'local-uid',
        payerUid: 'local-uid',
        totalAmount: bill.amount,
        dateMs: bill.dateMs,
        categoryName: const Value('餐饮'),
        status: const Value(1),
        createdAtMs: 1,
        updatedAtMs: 10,
      ));
      await db.linkBillToAaGroup(bill.id, _groupId);
      await _completeSettlement(db);
    });

Future<void> _expectDeleteRefused(WidgetTester tester) async {
  final warning = find.text('该 AA 账单已结算，不能再修改');
  for (var attempt = 0; attempt < 20 && warning.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300));
  expect(warning, findsOneWidget);
  expect(find.text('已删除 1 笔账单'), findsNothing);
  expect(find.text('撤销'), findsNothing);
  expect(tester.takeException(), isNull);
}

void _expectSettledReadOnly() {
  expect(find.byType(EditBillPage), findsOneWidget);
  expect(find.textContaining('已结算'), findsWidgets);
  expect(find.byType(NumberPad), findsNothing);
  expect(find.byType(TextField), findsNothing);
  expect(find.text('保存'), findsNothing);
  expect(find.text('再记'), findsNothing);
  expect(find.byIcon(Icons.delete_outline), findsNothing);
  expect(find.byTooltip('图片识别记账'), findsNothing);
  expect(find.byIcon(Icons.photo_camera_outlined), findsNothing);
}

void main() {
  for (final ownerView in [true, false]) {
    testWidgets('已结算原始 AA ${ownerView ? '垫付方' : '伙伴份额'}只能查看',
        (tester) async {
      final db = TestAppDatabase();
      final bill = await _seedOriginalAa(db, ownerView: ownerView);
      final before = await _snapshot(db);

      await pumpPage(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showBillDetailSheet(context: context, bill: bill),
            child: const Text('查看已结算账单'),
          ),
        ),
        db: db,
      );
      await tester.tap(find.text('查看已结算账单'));
      await settleProviders(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.text('修改'));
      await settleProviders(tester);

      _expectSettledReadOnly();
      expect(await _snapshot(db), before);
      await tester.binding.handlePopRoute();
      await settleProviders(tester);
      expect(find.byType(BillDetailPage), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('未结算原始 AA 编辑页收到后台结算后自动变只读', (tester) async {
    final db = TestAppDatabase();
    final bill = await _seedOriginalAa(db, ownerView: true, settled: false);
    await pumpPage(tester, EditBillPage(bill: bill), db: db);
    expect(find.byType(NumberPad), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);

    await tester.runAsync(() => _completeSettlement(db));
    await settleProviders(tester);

    _expectSettledReadOnly();
    expect((await db.getAllBills()).single.toJson(), bill.toJson());
    final group = (await db.getAaGroup(_groupId))!;
    expect(group.settled, isTrue);
    expect(group.settlementId, _settlementId);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('保存查重等待期间后台结算，继续保存不能改原始账单或结算',
      (tester) async {
    late _DelayedSimilarBillsDatabase db;
    late Bill bill;
    // 门闩及数据库初始化都在真实 Zone，错误不能跨假 Zone 后丢失。
    await tester.runAsync(() async {
      db = _DelayedSimilarBillsDatabase();
      bill = await _seedOriginalAa(db, ownerView: true, settled: false);
    });
    await pumpPage(tester, BillDetailPage(bill: bill), db: db);
    var saveCompleted = false;
    Object? saveError;
    addTearDown(() async {
      if (!db.releaseLookup.isCompleted) {
        await tester.runAsync(() async {
          db.releaseLookup.complete();
        });
        if (db.lookupEntered.isCompleted) {
          await _drainSave(tester, () => saveCompleted);
        }
      }
    });
    await tester.tap(find.text('修改'));
    await settleProviders(tester);
    await tester.enterText(find.byType(TextField), '结算后不应保存的备注');
    tester.testTextInput.hide();
    await tester.pump();
    final pad = tester.widget<NumberPad>(find.byType(NumberPad));
    pad.onClear();
    pad.onKey('9');
    pad.onKey('9');
    await tester.pump();

    await tester.runAsync(() async {
      // 收集完整保存 Future 的结果和异常，再交替排空真实与假 Zone。
      unawaited(Future<void>.sync(() async {
        await (pad.onSave as dynamic)();
      }).then((_) {
        saveCompleted = true;
      }, onError: (Object error, StackTrace stack) {
        saveError = error;
        saveCompleted = true;
      }));
      await db.lookupEntered.future.timeout(const Duration(seconds: 2));
    });
    expect(saveCompleted, isFalse);
    await tester.runAsync(() => _completeSettlement(db));
    await settleProviders(tester);
    final afterSettlement = await _snapshot(db);

    await tester.runAsync(() async {
      db.releaseLookup.complete();
    });
    await _drainSave(tester, () => saveCompleted);
    expect(saveCompleted, isTrue, reason: '保存应在有界排空后完成');
    expect(saveError, isNull, reason: '编辑页必须处理后台结算导致的保存拒绝');
    await settleProviders(tester);

    expect(await _snapshot(db), afterSettlement);
    expect((await db.getAllBills()).single.toJson(), bill.toJson());
    expect((await db.getAaGroup(_groupId))!.settled, isTrue);
    expect((await db.getAaGroup(_groupId))!.status, 1);
    expect(await db.getAllSettlements(), hasLength(1));
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('普通编辑页删除确认期间转 AA 并结算，旧删除被拒绝且保留编辑页',
      (tester) async {
    final db = TestAppDatabase();
    final bill = await _seedOrdinaryBill(db);
    await pumpPage(tester, BillDetailPage(bill: bill), db: db);
    await tester.tap(find.text('修改'));
    await settleProviders(tester);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await settleProviders(tester);
    expect(find.text('删除账单'), findsOneWidget);

    // 确认框仍使用普通账单快照，但真正的账单现已关联已结算 AA。
    await tester.runAsync(() => _convertAndSettle(db, bill));
    await settleProviders(tester);
    final afterSettlement = await _snapshot(db);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
    });
    await _expectDeleteRefused(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(find.byType(NumberPad), findsOneWidget);
    expect(await _snapshot(db), afterSettlement);
    expect((await db.getAllBills()).single.deletedAt, isNull);
    await disposePage(tester, db);
  });

  testWidgets('明细保留普通账单旧快照时，滑动删除已结算 AA 不误报成功',
      (tester) async {
    final db = TestAppDatabase();
    final bill = await _seedOrdinaryBill(db);
    await pumpPage(tester, const BillsPage(), db: db, overrides: [
      // 模拟当前帧尚未收到新记录，数据库和删除服务仍为真实实现。
      monthBillsProvider.overrideWith((ref) => Stream.value([bill])),
    ]);
    await tester.drag(find.text(bill.note), const Offset(-100, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('删除'), findsOneWidget);

    await tester.runAsync(() => _convertAndSettle(db, bill));
    final afterSettlement = await _snapshot(db);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('删除'));
    });
    await _expectDeleteRefused(tester);

    expect(find.byType(BillsPage), findsOneWidget);
    expect(find.text(bill.note), findsOneWidget);
    expect(await _snapshot(db), afterSettlement);
    expect((await db.getAllBills()).single.deletedAt, isNull);
    await disposePage(tester, db);
  });
}
