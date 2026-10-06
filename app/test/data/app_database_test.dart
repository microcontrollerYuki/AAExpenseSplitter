import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';

import '../helpers/test_support.dart';

/// 用可注入 executor 打开（迁移/重开场景需要文件库）
class DbWithExecutor extends AppDatabase {
  DbWithExecutor(QueryExecutor e) : super(executor: e);
}

void main() {
  late TestAppDatabase db;

  setUp(() async {
    db = TestAppDatabase();
    // beforeOpen 播种在首次查询前触发，这里显式等待完成
    await db.getAllAccounts();
  });

  tearDown(() async {
    await db.close();
  });

  group('beforeOpen 预置播种', () {
    test('空库种子：18 个分类（12支出+5收入+1AA往来）与 4 个账户', () async {
      final cats = await db.getAllCategories();
      expect(cats.length, 18);
      expect(cats.where((c) => c.kind == 0).length, 12);
      expect(cats.where((c) => c.kind == 1).length, 5);
      expect(cats.where((c) => c.kind == 2).length, 1);
      final accs = await db.getAllAccounts();
      expect(accs.map((a) => a.id), containsAll([
        'acc_cash',
        'acc_wechat',
        'acc_alipay',
        'acc_bank',
      ]));
    });

    test('重开后不重复播种；缺失的 AA 往来分类与账户会被补齐', () async {
      final path =
          '${Directory.systemTemp.createTempSync('aa_db_reopen').path}/r.sqlite';
      final first = DbWithExecutor(NativeDatabase(File(path)));
      await first.getAllAccounts(); // 触发播种
      expect((await first.getAllCategories()).length, 18);
      // 模拟 v1 升级库缺 marker / 被清掉的账户
      await first.customStatement(
          "DELETE FROM categories WHERE id = 'cat_aa_marker'");
      await first.customStatement('DELETE FROM accounts');
      await first.close();

      final second = DbWithExecutor(NativeDatabase(File(path)));
      await second.getAllAccounts();
      final cats = await second.getAllCategories();
      final accs = await second.getAllAccounts();
      // 分类未清空 → 不重播全部；marker 缺 → 单独补插
      expect(cats.any((c) => c.id == kAaMarkerCategoryId && c.kind == 2),
          isTrue);
      expect(cats.length, 18);
      // 账户被清空 → 重新播种 4 个
      expect(accs.length, 4);
      await second.close();
    });
  });

  group('v1 → v2 迁移', () {
    test('从 v1 库升级：建 AA 表、补 settlement_id 列、播种', () async {
      final dir = Directory.systemTemp.createTempSync('aa_db_migrate');
      final path = '${dir.path}/v1.sqlite';
      final raw = sqlite3.open(path);
      raw.execute('CREATE TABLE IF NOT EXISTS "accounts" ('
          '"id" TEXT NOT NULL PRIMARY KEY, "name" TEXT NOT NULL, '
          '"emoji" TEXT NOT NULL DEFAULT \'💰\', "type" INTEGER NOT NULL DEFAULT 3, '
          '"init_balance" INTEGER NOT NULL DEFAULT 0, '
          '"include_net_worth" INTEGER NOT NULL DEFAULT 1, '
          '"sort" INTEGER NOT NULL DEFAULT 0, "created_at" INTEGER NOT NULL)');
      raw.execute('CREATE TABLE IF NOT EXISTS "categories" ('
          '"id" TEXT NOT NULL PRIMARY KEY, "parent_id" TEXT NULL, '
          '"name" TEXT NOT NULL, "emoji" TEXT NOT NULL, "kind" INTEGER NOT NULL, '
          '"sort" INTEGER NOT NULL DEFAULT 0, "is_preset" INTEGER NOT NULL DEFAULT 1)');
      raw.execute('CREATE TABLE IF NOT EXISTS "bills" ('
          '"id" TEXT NOT NULL PRIMARY KEY, "type" INTEGER NOT NULL, '
          '"amount" INTEGER NOT NULL, "category_id" TEXT NULL, '
          '"account_id" TEXT NOT NULL, "to_account_id" TEXT NULL, '
          '"date_ms" INTEGER NOT NULL, "note" TEXT NOT NULL DEFAULT \'\', '
          '"is_aa" INTEGER NOT NULL DEFAULT 0, "aa_group_id" TEXT NULL, '
          '"created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, '
          '"deleted_at" INTEGER NULL)');
      raw.execute('PRAGMA user_version = 1');
      raw.dispose();

      final db2 = DbWithExecutor(NativeDatabase(File(path)));
      // 迁移后新表可用
      await db2.setMeta('k', 'v');
      expect(await db2.getMeta('k'), 'v');
      await db2.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: 'u1',
        payerUid: 'u1',
        totalAmount: 1000,
        dateMs: 100,
        createdAtMs: 1,
        updatedAtMs: 1,
      ));
      expect((await db2.getAllAaGroups()).length, 1);
      await db2.upsertSettlement(SettlementsCompanion.insert(
        id: 's1',
        receiverUid: 'u1',
        amount: 500,
        dateMs: 2,
        cutoffMs: 2,
        createdAtMs: 2,
      ));
      expect((await db2.getAllSettlements()).length, 1);
      // bills 新增的 settlement_id 列可写可查
      await db2.upsertBill(
        id: 'b1',
        type: 2,
        amount: 500,
        accountId: 'acc_cash',
        dateMs: 5,
        settlementId: 's1',
      );
      expect(await db2.hasSettlementBill('s1'), isTrue);
      // 播种在迁移后照常执行
      expect((await db2.getAllCategories()).length, 18);
      await db2.close();
    });
  });

  group('账单 DAO', () {
    test('upsertBill 新增后再次 upsert 为更新（同 id）', () async {
      await db.upsertBill(
          id: 'b1',
          type: 0,
          amount: 100,
          categoryId: 'cat_food',
          accountId: 'acc_cash',
          dateMs: 1000,
          note: 'a');
      await db.upsertBill(
          id: 'b1',
          type: 0,
          amount: 200,
          categoryId: 'cat_food',
          accountId: 'acc_cash',
          dateMs: 1000,
          note: 'b');
      final bills = await db.watchAllBills().first;
      expect(bills.length, 1);
      expect(bills.first.amount, 200);
      expect(bills.first.note, 'b');
    });

    test('upsertBill 带 aaGroupId 时 isAa 置位；createdAt 可指定', () async {
      await db.upsertBill(
        id: 'b2',
        type: 0,
        amount: 100,
        accountId: 'acc_cash',
        dateMs: 1000,
        createdAt: 123,
        aaGroupId: 'g9',
      );
      final bills = await db.watchAllBills().first;
      expect(bills.first.isAa, isTrue);
      expect(bills.first.aaGroupId, 'g9');
      expect(bills.first.createdAt, 123);
    });

    test('linkBillToAaGroup 更新既有账单', () async {
      await db.upsertBill(
          id: 'b3',
          type: 0,
          amount: 100,
          accountId: 'acc_cash',
          dateMs: 1000);
      await db.linkBillToAaGroup('b3', 'grp-1');
      final bills = await db.watchAllBills().first;
      expect(bills.first.aaGroupId, 'grp-1');
      expect(bills.first.isAa, isTrue);
    });

    test('watchAllBills 按日期+创建时间倒序且排除软删除', () async {
      await db.upsertBill(
          id: 'o1',
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: 100,
          createdAt: 1);
      await db.upsertBill(
          id: 'o2',
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: 200,
          createdAt: 1);
      await db.upsertBill(
          id: 'o3',
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: 200,
          createdAt: 9);
      var bills = await db.watchAllBills().first;
      expect(bills.map((b) => b.id).toList(), ['o3', 'o2', 'o1']);

      await db.softDeleteBill('o3');
      bills = await db.watchAllBills().first;
      expect(bills.map((b) => b.id).toList(), ['o2', 'o1']);

      await db.restoreBill('o3');
      bills = await db.watchAllBills().first;
      expect(bills.length, 3);
    });

    test('watchBillsOfRange 只含区间内的未删除账单', () async {
      await db.upsertBill(
          id: 'in1',
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: 150);
      await db.upsertBill(
          id: 'out',
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: 300);
      await db.upsertBill(
          id: 'in2',
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: 250);
      await db.softDeleteBill('in2');
      final bills = await db.watchBillsOfRange(100, 200).first;
      expect(bills.map((b) => b.id), ['in1']);
    });

    test('findSimilarBills：同类型同金额同日命中，可排除自身/软删除', () async {
      final day = DateTime(2026, 10, 5, 12);
      final ms = day.millisecondsSinceEpoch;
      await db.upsertBill(
          id: 's1',
          type: 0,
          amount: 880,
          accountId: 'acc_cash',
          dateMs: ms);
      await db.upsertBill(
          id: 's2',
          type: 1,
          amount: 880,
          accountId: 'acc_cash',
          dateMs: ms); // 类型不同
      await db.upsertBill(
          id: 's3',
          type: 0,
          amount: 880,
          accountId: 'acc_cash',
          dateMs: ms + 3600 * 1000); // 同日不同时刻
      await db.upsertBill(
          id: 's4',
          type: 0,
          amount: 880,
          accountId: 'acc_cash',
          dateMs: ms + 86400 * 1000); // 次日
      await db.upsertBill(
          id: 's5',
          type: 0,
          amount: 880,
          accountId: 'acc_cash',
          dateMs: ms); // 之后被软删
      await db.softDeleteBill('s5');

      final similar = await db.findSimilarBills(
          type: 0, amount: 880, dateMs: ms);
      expect(similar.map((b) => b.id).toSet(), {'s1', 's3'});

      final excluding = await db.findSimilarBills(
          type: 0, amount: 880, dateMs: ms, excludeId: 's1');
      expect(excluding.map((b) => b.id), ['s3']);
    });
  });

  group('账户 DAO', () {
    test('upsertAccount 插入与更新、getAccount、watchAccounts 按 sort 排序', () async {
      await db.upsertAccount(
          id: 'x1',
          name: '公交卡',
          emoji: '🚌',
          type: 3,
          initBalance: 50,
          includeNetWorth: true,
          sort: -1);
      var acc = await db.getAccount('x1');
      expect(acc!.name, '公交卡');

      await db.upsertAccount(
          id: 'x1',
          name: '交通卡',
          emoji: '🚌',
          type: 3,
          initBalance: 60,
          includeNetWorth: false,
          sort: -1);
      acc = await db.getAccount('x1');
      expect(acc!.name, '交通卡');
      expect(acc.includeNetWorth, isFalse);

      final all = await db.watchAccounts().first;
      expect(all.first.id, 'x1'); // sort=-1 排最前
    });

    test('deleteAccount 删除指定账户', () async {
      await db.upsertAccount(
          id: 'tmp',
          name: '临时',
          emoji: '💰',
          type: 0,
          initBalance: 0,
          includeNetWorth: true,
          sort: 99);
      await db.deleteAccount('tmp');
      expect(await db.getAccount('tmp'), isNull);
    });

    test('billCountOfAccount 统计转出与转入且排除软删除', () async {
      await db.upsertBill(
          id: 't1',
          type: 0,
          amount: 1,
          accountId: 'acc_bank',
          dateMs: 1);
      await db.upsertBill(
          id: 't2',
          type: 2,
          amount: 1,
          accountId: 'acc_cash',
          toAccountId: 'acc_bank',
          dateMs: 2);
      await db.upsertBill(
          id: 't3',
          type: 0,
          amount: 1,
          accountId: 'acc_bank',
          dateMs: 3);
      await db.softDeleteBill('t3');
      expect(await db.billCountOfAccount('acc_bank'), 2);
    });
  });

  group('AA 分摊组 DAO', () {
    test('upsertAaGroup / getAaGroup / getAllAaGroups / watchAaGroups 排序',
        () async {
      Future<void> add(String id, int dateMs, int createdMs) =>
          db.upsertAaGroup(AaGroupsCompanion.insert(
            id: id,
            ownerUid: 'u1',
            payerUid: 'u1',
            totalAmount: 100,
            dateMs: dateMs,
            createdAtMs: createdMs,
            updatedAtMs: createdMs,
          ));
      await add('g1', 100, 1);
      await add('g2', 300, 2);
      await add('g3', 300, 5);
      expect((await db.getAaGroup('g2'))!.totalAmount, 100);
      expect(await db.getAaGroup('ghost'), isNull);
      expect((await db.getAllAaGroups()).length, 3);
      final watched = await db.watchAaGroups().first;
      // dateMs 降序，同日按 createdAtMs 降序
      expect(watched.map((g) => g.id).toList(), ['g3', 'g2', 'g1']);
    });

    test('markSettledUpTo 只核销 cutoff 前未结算的组', () async {
      // insertOnConflictUpdate 要求 companion 自带必填字段，已结算的组在插入时即带状态
      Future<void> add(String id, int dateMs,
              {bool settled = false, String? settleId}) =>
          db.upsertAaGroup(AaGroupsCompanion.insert(
            id: id,
            ownerUid: 'u1',
            payerUid: 'u1',
            totalAmount: 100,
            dateMs: dateMs,
            createdAtMs: 1,
            updatedAtMs: 1,
            settled: Value(settled),
            settlementId: Value(settleId),
          ));
      await add('g1', 100);
      await add('g2', 200);
      await add('g3', 50, settled: true, settleId: 'old-settle');
      await db.markSettledUpTo(150, 'new-settle');

      final groups = await db.getAllAaGroups();
      final byId = {for (final g in groups) g.id: g};
      expect(byId['g1']!.settled, isTrue);
      expect(byId['g1']!.settlementId, 'new-settle');
      expect(byId['g2']!.settled, isFalse); // 晚于 cutoff
      expect(byId['g2']!.settlementId, isNull);
      expect(byId['g3']!.settlementId, 'old-settle'); // 已结算不被改写
    });
  });

  group('结算 DAO', () {
    test('upsert / get / getAll / watch 排序 / hasSettlementBill', () async {
      Future<void> add(String id, int dateMs) =>
          db.upsertSettlement(SettlementsCompanion.insert(
            id: id,
            receiverUid: 'u1',
            amount: 100,
            dateMs: dateMs,
            cutoffMs: dateMs,
            createdAtMs: dateMs,
          ));
      await add('s1', 100);
      await add('s2', 300);
      expect((await db.getSettlement('s1'))!.amount, 100);
      expect(await db.getSettlement('ghost'), isNull);
      expect((await db.getAllSettlements()).length, 2);
      final watched = await db.watchSettlements().first;
      expect(watched.map((s) => s.id).toList(), ['s2', 's1']);

      expect(await db.hasSettlementBill('s1'), isFalse);
      await db.upsertBill(
        id: 'sb',
        type: 2,
        amount: 100,
        accountId: 'acc_cash',
        toAccountId: 'acc_bank',
        dateMs: 1,
        settlementId: 's1',
      );
      expect(await db.hasSettlementBill('s1'), isTrue);
    });
  });

  group('键值 Meta DAO', () {
    test('get/set/delete 与 watchMeta', () async {
      expect(await db.getMeta('nope'), isNull);
      await db.setMeta('k1', 'v1');
      expect(await db.getMeta('k1'), 'v1');
      await db.setMeta('k1', 'v2'); // 覆盖
      expect(await db.getMeta('k1'), 'v2');
      final rows = await db.watchMeta().first;
      expect(rows.any((r) => r.key == 'k1' && r.value == 'v2'), isTrue);
      await db.deleteMeta('k1');
      expect(await db.getMeta('k1'), isNull);
    });
  });
}
