import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/providers.dart';

import 'helpers/test_support.dart';

void main() {
  group('databaseProvider（默认构造走真实连接）', () {
    test('创建文件库并可查询，dispose 时关闭', () async {
      final fake = FakePathProvider();
      PathProviderPlatform.instance = fake;
      final container = ProviderContainer();
      final db = container.read(databaseProvider);
      // 播种可查即代表连接与迁移正常
      expect((await db.getAllCategories()).length, 18);
      expect((await db.getAllAccounts()).length, 4);
      container.dispose(); // 触发 ref.onDispose(db.close)
      fake.cleanup();
    });
  });

  group('provider 数据流', () {
    late TestAppDatabase db;
    late ProviderContainer container;
    // riverpod 3：无监听的流 provider 容器 dispose 时可能因重建中报错，
    // 各用例自行挂常驻监听并登记到这里
    final subs = <ProviderSubscription>[];

    setUp(() async {
      db = TestAppDatabase();
      container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)]);
      await db.getAllAccounts();
    });

    tearDown(() async {
      for (final s in subs) {
        s.close();
      }
      subs.clear();
      container.dispose();
      await db.close();
    });

    test('metaProvider 映射为 key-value 表', () async {
      await db.setMeta('k', 'v');
      subs.add(container.listen(metaProvider, (_, __) {}));
      final map = await container.read(metaProvider.future);
      expect(map['k'], 'v');
    });

    test('accountsProvider / categoriesProvider 暴露播种数据', () async {
      subs.add(container.listen(accountsProvider, (_, __) {}));
      subs.add(container.listen(categoriesProvider, (_, __) {}));
      expect((await container.read(accountsProvider.future)).length, 4);
      expect((await container.read(categoriesProvider.future)).length, 18);
    });

    test('allBillsProvider 与 monthBillsProvider 按月过滤', () async {
      final now = DateTime.now();
      final thisMonth = DateTime(now.year, now.month, 15).millisecondsSinceEpoch;
      final prevMonth =
          DateTime(now.year, now.month - 1, 15).millisecondsSinceEpoch;
      await db.upsertBill(
          id: 'in', type: 0, amount: 1, accountId: 'acc_cash', dateMs: thisMonth);
      await db.upsertBill(
          id: 'out',
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: prevMonth);
      subs.add(container.listen(allBillsProvider, (_, __) {}));
      subs.add(container.listen(monthBillsProvider, (_, __) {}));

      final all = await container.read(allBillsProvider.future);
      expect(all.length, 2);

      final month = await container.read(monthBillsProvider.future);
      expect(month.map((b) => b.id), ['in']);
    });

    test('monthBillsProvider 跟随 selectedMonthProvider 切换', () async {
      final now = DateTime.now();
      final prevMonth =
          DateTime(now.year, now.month - 1, 15).millisecondsSinceEpoch;
      await db.upsertBill(
          id: 'prev',
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: prevMonth);
      subs.add(container.listen(monthBillsProvider, (_, __) {}));

      // 默认选中当前月 → 空
      expect(await container.read(monthBillsProvider.future), isEmpty);

      // 切到上月，等 drift watch 流重新查询发射
      container.read(selectedMonthProvider.notifier).shift(-1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final v = container.read(monthBillsProvider).value ?? const <Bill>[];
      expect(v.map((b) => b.id), ['prev']);
    });

    test('monthBillsProvider 12月月初与月末归当月，次年零点只归下月', () async {
      final initialMonth = container.read(selectedMonthProvider);
      container.read(selectedMonthProvider.notifier).shift(12 - initialMonth.month);
      final selectedMonth = container.read(selectedMonthProvider);
      final monthStart = DateTime(selectedMonth.year, selectedMonth.month, 1)
          .millisecondsSinceEpoch;
      final nextMonthStart =
          DateTime(selectedMonth.year, selectedMonth.month + 1, 1)
              .millisecondsSinceEpoch;
      for (final entry in {
        'month-start': monthStart,
        'month-last-ms': nextMonthStart - 1,
        'next-month-start': nextMonthStart,
      }.entries) {
        await db.upsertBill(
          id: entry.key,
          type: 0,
          amount: 1,
          accountId: 'acc_cash',
          dateMs: entry.value,
        );
      }

      final nextMonthEmission = Completer<List<Bill>>();
      subs.add(container.listen<AsyncValue<List<Bill>>>(
        monthBillsProvider,
        (_, next) {
          final bills = next.value;
          if (!next.isLoading &&
              bills != null &&
              bills.length == 1 &&
              bills.single.id == 'next-month-start' &&
              !nextMonthEmission.isCompleted) {
            nextMonthEmission.complete(bills);
          }
        },
      ));

      final current = await container
          .read(monthBillsProvider.future)
          .timeout(const Duration(seconds: 2));
      expect(current.map((b) => b.id), ['month-last-ms', 'month-start']);

      container.read(selectedMonthProvider.notifier).shift(1);
      expect(container.read(selectedMonthProvider),
          DateTime(selectedMonth.year + 1, 1, 1));
      final next =
          await nextMonthEmission.future.timeout(const Duration(seconds: 2));
      expect(next.map((b) => b.id), ['next-month-start']);
    });

    test('aaGroupsProvider / settlementsProvider 暴露写入数据', () async {
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: 'u',
        payerUid: 'u',
        totalAmount: 1,
        dateMs: 1,
        createdAtMs: 1,
        updatedAtMs: 1,
      ));
      await db.upsertSettlement(SettlementsCompanion.insert(
        id: 's1',
        receiverUid: 'u',
        amount: 1,
        dateMs: 1,
        cutoffMs: 1,
        createdAtMs: 1,
      ));
      subs.add(container.listen(aaGroupsProvider, (_, __) {}));
      subs.add(container.listen(settlementsProvider, (_, __) {}));
      expect((await container.read(aaGroupsProvider.future)).length, 1);
      expect((await container.read(settlementsProvider.future)).length, 1);
    });
  });

  group('selectedMonthProvider', () {
    test('shift 前后月份翻页且锚定到 1 号', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(selectedMonthProvider.notifier);
      final now = container.read(selectedMonthProvider);
      notifier.shift(-1);
      final prev = container.read(selectedMonthProvider);
      expect(prev, DateTime(now.year, now.month - 1, 1));
      notifier.shift(2);
      expect(container.read(selectedMonthProvider),
          DateTime(now.year, now.month + 1, 1));
    });
  });
}
