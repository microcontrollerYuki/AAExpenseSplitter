import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';

import '../helpers/test_support.dart';

class _DelayedSettlementDatabase extends TestAppDatabase {
  final saveEntered = Completer<void>();
  final releaseSave = Completer<void>();
  final saveFinished = Completer<void>();

  @override
  Future<bool> updateSettlementBillLocalFields({
    required String billId,
    required String settlementId,
    required String accountId,
    required String note,
  }) async {
    saveEntered.complete();
    await releaseSave.future;
    final changed = await super.updateSettlementBillLocalFields(
      billId: billId,
      settlementId: settlementId,
      accountId: accountId,
      note: note,
    );
    saveFinished.complete();
    return changed;
  }
}

Future<Bill> _seedSettlement(TestAppDatabase db, int type) async {
  await db.getAllAccounts();
  await db.upsertBill(
    id: 'settlement-bill-$type',
    type: type,
    amount: 1234,
    categoryId: type == 1 ? 'inc_other' : 'cat_food',
    accountId: 'acc_cash',
    dateMs: DateTime(2026, 10, 3, 14, 25).millisecondsSinceEpoch,
    note: '结算前备注',
    createdAt: 123456,
    settlementId: 'settlement-$type',
  );
  return (await db.getAllBills()).single;
}

Future<void> _openSettlementEditor(WidgetTester tester) async {
  expect(find.byType(BillDetailPage), findsOneWidget);
  expect(find.text('AA 结算生成的收支明细'), findsOneWidget);
  await tester.tap(find.text('修改'));
  await settleProviders(tester);
  expect(find.text('修改结算账单'), findsOneWidget);
  expect(find.text('仅修改本机账户和备注，不影响双方结算。'), findsOneWidget);
  expect(find.byType(TextField), findsOneWidget);
  expect(find.text('保存'), findsOneWidget);
  expect(find.byType(NumberPad), findsNothing);
  expect(find.byType(FilterChip), findsNothing);
  for (final typeLabel in ['支出', '收入', '转账']) {
    expect(find.text(typeLabel), findsNothing);
  }
  expect(find.byIcon(Icons.delete_outline), findsNothing);
  expect(find.byTooltip('图片识别记账'), findsNothing);
}

Future<void> _changeLocalFields(
  WidgetTester tester, {
  String note = '本机私有备注',
}) async {
  await tester.tap(find.text('💵 现金'));
  await settleProviders(tester);
  expect(find.text('选择账户'), findsOneWidget);
  expect(find.widgetWithText(ListTile, 'AA挂账'), findsNothing);
  await tester.tap(find.widgetWithText(ListTile, '微信'));
  await settleProviders(tester);
  expect(find.text('💚 微信'), findsOneWidget);
  await tester.enterText(find.byType(TextField), note);
  tester.testTextInput.hide();
  await tester.pump();
}

Future<void> _saveSettlement(WidgetTester tester) async {
  await tester.ensureVisible(find.text('保存'));
  await tester.runAsync(() async {
    await tester.tap(find.text('保存'));
  });
  for (var i = 0;
      i < 50 && find.byType(EditBillPage).evaluate().isNotEmpty;
      i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(EditBillPage), findsNothing);
  await settleProviders(tester);
}

void _expectOnlyLocalFieldsChanged(Bill before, Bill after, String note) {
  // 比较所有持久化字段，仅账户、备注、更新时间允许变化。
  final original = Map<String, dynamic>.from(before.toJson())
    ..remove('accountId')
    ..remove('note')
    ..remove('updatedAt');
  final saved = Map<String, dynamic>.from(after.toJson())
    ..remove('accountId')
    ..remove('note')
    ..remove('updatedAt');
  expect(saved, original);
  expect(after.accountId, 'acc_wechat');
  expect(after.note, note);
  expect(after.updatedAt, greaterThanOrEqualTo(before.updatedAt));
  expect(after.settlementId, isNotNull);
  expect(after.aaGroupId, isNull);
}

void main() {
  test('结算本机字段更新拒绝不存在账户与真实存在的AA挂账账户', () async {
    final db = TestAppDatabase();
    addTearDown(db.close);
    final before = await _seedSettlement(db, 1);
    await db.upsertAccount(
      id: kAaCreditAccountId,
      name: 'AA挂账',
      emoji: '🤝',
      type: 4,
      initBalance: 0,
      includeNetWorth: false,
      sort: 99,
    );
    expect(await db.getAccount(kAaCreditAccountId), isNotNull);
    for (final accountId in ['missing-account', kAaCreditAccountId]) {
      final changed = await db.updateSettlementBillLocalFields(
        billId: before.id,
        settlementId: before.settlementId!,
        accountId: accountId,
        note: '不应保存',
      );
      expect(changed, isFalse, reason: accountId);
      expect((await db.getAllBills()).single.toJson(), before.toJson());
    }
  });

  test('结算本机字段更新拒绝错关联、软删除、旧转账、混合记录及缺失记录', () async {
    final db = TestAppDatabase();
    addTearDown(db.close);
    final valid = await _seedSettlement(db, 1);
    for (final row in [
      (id: 'deleted', type: 0, sid: 'deleted-sid', group: null),
      (id: 'legacy', type: 2, sid: 'legacy-sid', group: null),
      (id: 'mixed', type: 0, sid: 'mixed-sid', group: 'mixed-group'),
    ]) {
      await db.upsertBill(
        id: row.id,
        type: row.type,
        amount: 2500,
        accountId: 'acc_cash',
        toAccountId: row.type == 2 ? 'acc_alipay' : null,
        categoryId: 'cat_food',
        dateMs: 456789,
        aaGroupId: row.group,
        settlementId: row.sid,
      );
    }
    await db.softDeleteBill('deleted');
    Future<Map<String, dynamic>> allRows() async => {
          for (final b in await db.select(db.bills).get()) b.id: b.toJson(),
        };
    final before = await allRows();
    for (final attempt in [
      (id: valid.id, sid: 'wrong-settlement'),
      (id: 'deleted', sid: 'deleted-sid'),
      (id: 'legacy', sid: 'legacy-sid'),
      (id: 'mixed', sid: 'mixed-sid'),
      (id: 'missing-bill', sid: 'missing-sid'),
    ]) {
      final changed = await db.updateSettlementBillLocalFields(
        billId: attempt.id,
        settlementId: attempt.sid,
        accountId: 'acc_wechat',
        note: '不应复活或改关联',
      );
      expect(changed, isFalse, reason: attempt.id);
      expect(await allRows(), before, reason: attempt.id);
    }
  });

  test('结算编辑使用过期快照保存时保留数据库最新非本机字段', () async {
    final db = TestAppDatabase();
    addTearDown(db.close);
    final pageSnapshot = await _seedSettlement(db, 1);
    final latestDate = pageSnapshot.dateMs + 86400000;
    // 模拟编辑页打开后另一处更新数据；旧页面只能提交账户和备注。
    await (db.update(db.bills)
          ..where((b) => b.id.equals(pageSnapshot.id)))
        .write(BillsCompanion(
      type: const Value(0),
      amount: const Value(9876),
      dateMs: Value(latestDate),
      categoryId: const Value('cat_shopping'),
      createdAt: const Value(654321),
    ));
    final latest = (await db.getAllBills()).single;
    expect(latest.amount, isNot(pageSnapshot.amount));
    expect(latest.type, isNot(pageSnapshot.type));
    final changed = await db.updateSettlementBillLocalFields(
      billId: pageSnapshot.id,
      settlementId: pageSnapshot.settlementId!,
      accountId: 'acc_wechat',
      note: '仅更新私有字段',
    );
    expect(changed, isTrue);
    final after = (await db.getAllBills()).single;
    _expectOnlyLocalFieldsChanged(latest, after, '仅更新私有字段');
    expect(after.amount, 9876);
    expect(after.dateMs, latestDate);
    expect(after.categoryId, 'cat_shopping');
    expect(after.type, 0);
    expect(after.createdAt, 654321);
    expect(after.settlementId, pageSnapshot.settlementId);
  });

  testWidgets('保存等待中系统返回时完成写库只停留详情，不多退首页', (tester) async {
    late _DelayedSettlementDatabase db;
    // 控制真实异步 DAO 的信号也必须在真实 Zone 创建，避免等待 fake microtask。
    await tester.runAsync(() async {
      db = _DelayedSettlementDatabase();
    });
    final before = await _seedSettlement(db, 1);
    await pumpPage(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showBillDetailSheet(context: context, bill: before),
          child: const Text('测试首页'),
        ),
      ),
      db: db,
    );
    addTearDown(() async {
      if (!db.releaseSave.isCompleted) {
        await tester.runAsync(() async {
          db.releaseSave.complete();
          if (db.saveEntered.isCompleted) {
            await db.saveFinished.future.timeout(const Duration(seconds: 2));
          }
        });
      }
    });
    await tester.tap(find.text('测试首页'));
    await settleProviders(tester);
    await _openSettlementEditor(tester);
    await _changeLocalFields(tester, note: '返回竞态也应保存');
    await tester.ensureVisible(find.text('保存'));
    await tester.runAsync(() async {
      await tester.tap(find.text('保存'));
      await db.saveEntered.future.timeout(const Duration(seconds: 1));
    });
    // 模拟系统返回：编辑页已经不是当前路由，退出动画期间 State 仍 mounted。
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.byType(EditBillPage, skipOffstage: false), findsOneWidget);
    await tester.runAsync(() async {
      db.releaseSave.complete();
      await db.saveFinished.future.timeout(const Duration(seconds: 2));
    });
    await settleProviders(tester);

    expect(find.byType(EditBillPage), findsNothing);
    expect(find.byType(BillDetailPage), findsOneWidget);
    // Modal detail retains the underlying route; it must still be current.
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.byType(BillDetailPage)))!.isCurrent,
      isTrue,
    );
    expect(find.text('返回竞态也应保存'), findsOneWidget);
    _expectOnlyLocalFieldsChanged(
      before,
      (await db.getAllBills()).single,
      '返回竞态也应保存',
    );
    await disposePage(tester, db);
  });

  for (final type in [0, 1]) {
    final direction = type == 1 ? '收入' : '支出';
    testWidgets('结算$direction仅编辑本机账户和备注，详情保留结算身份', (tester) async {
      final db = TestAppDatabase();
      final before = await _seedSettlement(db, type);
      await pumpPage(tester, BillDetailPage(bill: before), db: db);

      await _openSettlementEditor(tester);
      await _changeLocalFields(tester);
      await _saveSettlement(tester);

      final after = (await db.getAllBills()).single;
      _expectOnlyLocalFieldsChanged(before, after, '本机私有备注');
      expect(find.text('AA 结算生成的收支明细'), findsOneWidget);
      expect(find.text('本机私有备注'), findsOneWidget);
      expect(find.text('💚 微信'), findsOneWidget);
      expect(find.text(type == 1 ? '+¥ 12.34' : '-¥ 12.34'), findsOneWidget);
      // 重新进入实际编辑页，必须沿用刚保存的账户和备注。
      await _openSettlementEditor(tester);
      expect(find.text('💚 微信'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '本机私有备注');
      await disposePage(tester, db);
    });
  }

  testWidgets('关闭结算编辑时账户、备注和更新时间均未写库', (tester) async {
    final db = TestAppDatabase();
    final before = await _seedSettlement(db, 1);
    await pumpPage(tester, BillDetailPage(bill: before), db: db);
    await _openSettlementEditor(tester);
    await _changeLocalFields(tester, note: '取消后不应落库');
    await tester.tap(find.byTooltip('关闭'));
    await settleProviders(tester);

    expect(find.byType(BillDetailPage), findsOneWidget);
    expect((await db.getAllBills()).single.toJson(), before.toJson());
    expect(find.text('结算前备注'), findsOneWidget);
    expect(find.text('取消后不应落库'), findsNothing);
    await disposePage(tester, db);
  });

  final lockedCases = <({String label, int type, String? group, String? sid})>[
    (label: '旧结算转账', type: 2, group: null, sid: 'legacy-settlement'),
    (label: 'AA伴生应收', type: 1, group: 'group-income', sid: null),
    (label: '带分摊组的结算记录', type: 0, group: 'group-mixed', sid: 'mixed'),
  ];
  for (final c in lockedCases) {
    testWidgets('${c.label}仍锁定且不提供保存或删除', (tester) async {
      final db = TestAppDatabase();
      await db.getAllAccounts();
      await db.upsertBill(
        id: 'locked',
        type: c.type,
        amount: 1234,
        categoryId: c.type == 1 ? 'cat_aa_marker' : 'cat_food',
        accountId: 'acc_cash',
        toAccountId: c.type == 2 ? 'acc_wechat' : null,
        dateMs: 123456,
        note: c.label,
        aaGroupId: c.group,
        settlementId: c.sid,
      );
      final before = (await db.getAllBills()).single;
      await pumpPage(tester, BillDetailPage(bill: before), db: db);
      await tester.tap(find.text('修改'));
      await settleProviders(tester);

      expect(find.text('AA 账单'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settleProviders(tester);
      expect((await db.getAllBills()).single.toJson(), before.toJson());
      await disposePage(tester, db);
    });
  }

  for (final type in [0, 1]) {
    testWidgets('单笔结算${type == 1 ? '收入' : '支出'}编辑后加密文件重导两次仍幂等',
        (tester) async {
      final previousPathProvider = PathProviderPlatform.instance;
      final pathProvider = FakePathProvider();
      PathProviderPlatform.instance = pathProvider;
      final source = TestAppDatabase();
      final local = TestAppDatabase();
      addTearDown(() async {
        await disposePage(tester, local);
        await tester.runAsync(source.close);
        PathProviderPlatform.instance = previousPathProvider;
        pathProvider.cleanup();
      });
      final sourceService = AaSyncService(source);
      final localService = AaSyncService(local);
      late String file;
      await tester.runAsync(() async {
        await source.getAllAccounts();
        await local.getAllAccounts();
        await sourceService.setupPairing(
            myName: '伙伴', partnerName: '本机', secret: 'settlement-edit-secret');
        await localService.setupPairing(
            myName: '本机', partnerName: '伙伴', secret: 'settlement-edit-secret');
        final sourceUid = (await source.getMeta('myUid'))!;
        final localUid = (await local.getMeta('myUid'))!;
        await source.setMeta('partnerUid', localUid);
        await local.setMeta('partnerUid', sourceUid);
        final payerUid = type == 1 ? localUid : sourceUid;
        await source.upsertAaGroup(AaGroupsCompanion.insert(
          id: 'only-covered-group',
          ownerUid: payerUid,
          payerUid: payerUid,
          totalAmount: 2468,
          dateMs: DateTime(2026, 10, 3, 14, 25).millisecondsSinceEpoch,
          categoryName: const Value('餐饮'),
          note: const Value('只覆盖一组'),
          status: const Value(1),
          createdAtMs: 1,
          updatedAtMs: 1,
        ));
        await sourceService.settle(accountId: 'acc_cash');
        file = await sourceService.exportSyncFile();
        await localService.importSyncFile(file);
      });

      final before = (await local.getAllBills()).single;
      expect(before.type, type);
      expect(before.amount, 1234);
      expect(before.settlementId, isNotNull);
      expect(before.aaGroupId, isNull);
      final groupSnapshot = (await local.getAllAaGroups()).single.toJson();
      final settlementSnapshot =
          (await local.getAllSettlements()).single.toJson();
      expect(await localService.computeNet(), 0);
      await pumpPage(tester, BillDetailPage(bill: before), db: local);
      await _openSettlementEditor(tester);
      await _changeLocalFields(tester, note: '加密重导必须保留的本机备注');
      await _saveSettlement(tester);
      final edited = (await local.getAllBills()).single;
      _expectOnlyLocalFieldsChanged(before, edited, '加密重导必须保留的本机备注');

      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.runAsync(() => localService.importSyncFile(file));
        await settleProviders(tester);
        // 只有这一笔结算账单，不能让同 settlementId 的另一行掩盖标识丢失。
        final rows = await local.select(local.bills).get();
        expect(rows.map((b) => b.id).toSet(), {before.id});
        expect(rows.single.toJson(), edited.toJson());
        expect((await local.getAllAaGroups()).single.toJson(), groupSnapshot);
        expect((await local.getAllSettlements()).single.toJson(),
            settlementSnapshot);
        expect(await localService.computeNet(), 0);
        expect(await sourceService.computeNet(), 0);
        expect(find.text('AA 结算生成的收支明细'), findsOneWidget);
        expect(find.text('加密重导必须保留的本机备注'), findsOneWidget);
        expect(find.text('💚 微信'), findsOneWidget);
      }
      await disposePage(tester, local);
    });
  }
}
