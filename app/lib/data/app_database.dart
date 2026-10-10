import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'presets.dart';

part 'app_database.g.dart';

/// 账户：type 0 现金 / 1 银行卡 / 2 信用卡 / 3 虚拟(微信/支付宝) / 4 AA挂账(M2)
class Accounts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get emoji => text().withDefault(const Constant('💰'))();
  IntColumn get type => integer().withDefault(const Constant(3))();
  IntColumn get initBalance => integer().withDefault(const Constant(0))(); // 分
  BoolColumn get includeNetWorth => boolean().withDefault(const Constant(true))();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 分类：kind 0 支出 / 1 收入 / 2 不计收支；parentId 为空即一级分类
class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get emoji => text()();
  IntColumn get kind => integer()();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  BoolColumn get isPreset => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 账单：type 0 支出 / 1 收入 / 2 转账 / 3 余额调节(预留)
/// amount 单位为分；isAa / aaGroupId 为 M2 AA 同步预留字段
class Bills extends Table {
  TextColumn get id => text()();
  IntColumn get type => integer()();
  IntColumn get amount => integer()();
  TextColumn get categoryId => text().nullable()();
  TextColumn get accountId => text()();
  TextColumn get toAccountId => text().nullable()();
  IntColumn get dateMs => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();
  BoolColumn get isAa => boolean().withDefault(const Constant(false))();
  TextColumn get aaGroupId => text().nullable()();
  TextColumn get settlementId => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// AA 分摊组：一笔被标记为 AA 的支出在双方账本间的全局记录（M2 文件同步）
class AaGroups extends Table {
  TextColumn get id => text()(); // 全局 uuid
  TextColumn get ownerUid => text()(); // 记录发起方设备 uid
  TextColumn get payerUid => text()(); // 实际垫付方 uid
  IntColumn get totalAmount => integer()(); // 分
  IntColumn get dateMs => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get categoryName => text().withDefault(const Constant(''))();
  TextColumn get categoryEmoji => text().withDefault(const Constant('🤝'))();
  IntColumn get status => integer().withDefault(const Constant(0))(); // 0待确认 1已确认 2已退回(挂起) 3已取消
  TextColumn get statusByUid => text().nullable()();
  IntColumn get statusAtMs => integer().nullable()();
  TextColumn get statusNote => text().nullable()(); // 退回理由（可选）
  BoolColumn get settled => boolean().withDefault(const Constant(false))();
  TextColumn get settlementId => text().nullable()();
  IntColumn get createdAtMs => integer()();
  IntColumn get updatedAtMs => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 结算记录：一方向另一方实际转账，核销截至 cutoffMs 的未结算 AA 账单
class Settlements extends Table {
  TextColumn get id => text()();
  TextColumn get receiverUid => text()(); // 收款方设备 uid
  IntColumn get amount => integer()();
  IntColumn get dateMs => integer()();
  IntColumn get cutoffMs => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();
  IntColumn get createdAtMs => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 本机键值存储：配对信息（uid / 昵称 / 口令）与同步时间戳
class MetaEntries extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'aa_expense.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

@DriftDatabase(
    tables: [Accounts, Categories, Bills, AaGroups, Settlements, MetaEntries])
class AppDatabase extends _$AppDatabase {
  /// [executor] 仅供测试注入（如 NativeDatabase.memory()），生产路径不变
  AppDatabase({QueryExecutor? executor}) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from == 1) {
            await m.createTable(aaGroups);
            await m.createTable(settlements);
            await m.createTable(metaEntries);
            await m.addColumn(bills, bills.settlementId);
          } else if (from == 2) {
            await m.addColumn(aaGroups, aaGroups.statusNote);
          }
        },
        beforeOpen: (details) async {
          final now = DateTime.now().millisecondsSinceEpoch;
          final hasCategory =
              await (select(categories)..limit(1)).getSingleOrNull();
          if (hasCategory == null) {
            await batch((b) {
              var i = 0;
              for (final c in kPresetExpenseCategories) {
                b.insert(categories, CategoriesCompanion.insert(
                    id: c.id,
                    name: c.name,
                    emoji: c.emoji,
                    kind: c.kind,
                    sort: Value(i++)));
              }
              for (final c in kPresetIncomeCategories) {
                b.insert(categories, CategoriesCompanion.insert(
                    id: c.id,
                    name: c.name,
                    emoji: c.emoji,
                    kind: c.kind,
                    sort: Value(i++)));
              }
              b.insert(categories, CategoriesCompanion.insert(
                  id: kAaMarkerCategoryId,
                  name: 'AA往来',
                  emoji: '🤝',
                  kind: 2,
                  sort: Value(90)));
            });
          }
          // v1 升级上来的库补插 AA 往来分类
          final hasMarker = await (select(categories)
                ..where((t) => t.id.equals(kAaMarkerCategoryId))
                ..limit(1))
              .getSingleOrNull();
          if (hasMarker == null) {
            await into(categories).insert(CategoriesCompanion.insert(
                id: kAaMarkerCategoryId,
                name: 'AA往来',
                emoji: '🤝',
                kind: 2,
                sort: const Value(90)));
          }
          final hasAccount = await (select(accounts)..limit(1)).getSingleOrNull();
          if (hasAccount == null) {
            await batch((b) {
              var i = 0;
              for (final a in kPresetAccounts) {
                b.insert(accounts, AccountsCompanion.insert(
                    id: a.id,
                    name: a.name,
                    emoji: Value(a.emoji),
                    type: Value(a.type),
                    sort: Value(i++),
                    createdAt: now));
              }
            });
          }
          // 兜底：已配对但「AA挂账」账户缺失（误删/异常）时补回，避免 AA 账单引用悬空账户
          final paired = await getMeta('pairSecret');
          if (paired != null) {
            final credit = await getAccount(kAaCreditAccountId);
            if (credit == null) {
              await into(accounts).insert(AccountsCompanion.insert(
                id: kAaCreditAccountId,
                name: 'AA挂账',
                createdAt: now,
                emoji: const Value('🤝'),
                type: const Value(4),
                initBalance: const Value(0),
                includeNetWorth: const Value(false),
                sort: const Value(99),
              ));
            }
          }
          // 历史 AA 份额按「奇数多出的 1 分归垫付方」口径重算（幂等，仅在不一致时写库）
          await normalizeAaShareAmounts();
        },
      );

  // ---------- 查询 ----------

  Stream<List<Account>> watchAccounts() =>
      (select(accounts)..orderBy([(t) => OrderingTerm.asc(t.sort)])).watch();

  Stream<List<Category>> watchCategories() =>
      (select(categories)..orderBy([(t) => OrderingTerm.asc(t.sort)])).watch();

  Stream<List<Bill>> watchAllBills() => (select(bills)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([
          (t) => OrderingTerm.desc(t.dateMs),
          (t) => OrderingTerm.desc(t.createdAt),
        ]))
      .watch();

  /// 未删除账单，按左闭右开区间 [startMs, endMs) 查询。
  Stream<List<Bill>> watchBillsOfRange(int startMs, int endMs) => (select(bills)
        ..where((t) =>
            t.deletedAt.isNull() &
            t.dateMs.isBiggerOrEqualValue(startMs) &
            t.dateMs.isSmallerThanValue(endMs))
        ..orderBy([
          (t) => OrderingTerm.desc(t.dateMs),
          (t) => OrderingTerm.desc(t.createdAt),
        ]))
      .watch();

  // ---------- 写入 ----------

  /// 以库中现有关联判断，旧页面不能靠清空 aaGroupId 改写已结算原始账单。
  /// 必须与对应写操作处于同一事务。
  Future<void> _checkAaBillNotSettled(String billId) async {
    final current = await (select(bills)
          ..where((t) => t.id.equals(billId)))
        .getSingleOrNull();
    final groupId = current?.aaGroupId;
    if (groupId == null) return;
    final group = await getAaGroup(groupId);
    if (group?.settled == true) {
      throw StateError('该 AA 账单已结算，不能再修改');
    }
  }

  Future<void> upsertBill({
    required String id,
    required int type,
    required int amount,
    String? categoryId,
    required String accountId,
    String? toAccountId,
    required int dateMs,
    String note = '',
    int? createdAt,
    String? aaGroupId,
    String? settlementId,
  }) =>
      transaction(() async {
        await _checkAaBillNotSettled(id);
        final now = DateTime.now().millisecondsSinceEpoch;
        await into(bills).insertOnConflictUpdate(BillsCompanion(
          id: Value(id),
          type: Value(type),
          amount: Value(amount),
          categoryId: Value(categoryId),
          accountId: Value(accountId),
          toAccountId: Value(toAccountId),
          dateMs: Value(dateMs),
          note: Value(note),
          isAa: Value(aaGroupId != null),
          aaGroupId: Value(aaGroupId),
          settlementId: Value(settlementId),
          createdAt: Value(createdAt ?? now),
          updatedAt: Value(now),
        ));
      });

  Future<void> linkBillToAaGroup(String billId, String groupId) =>
      (update(bills)..where((t) => t.id.equals(billId)))
          .write(BillsCompanion(
              isAa: const Value(true), aaGroupId: Value(groupId)));

  /// 结算收支仅改本机字段，不用页面快照重写金额或结算关联。
  Future<bool> updateSettlementBillLocalFields({
    required String billId,
    required String settlementId,
    required String accountId,
    required String note,
  }) =>
      transaction(() async {
        if (accountId == kAaCreditAccountId) return false;
        final account = await (select(accounts)
              ..where((t) => t.id.equals(accountId)))
            .getSingleOrNull();
        if (account == null) return false;
        final changed = await (update(bills)
              ..where((t) =>
                  t.id.equals(billId) &
                  t.deletedAt.isNull() &
                  t.settlementId.equals(settlementId) &
                  t.aaGroupId.isNull() &
                  t.type.isIn([0, 1])))
            .write(BillsCompanion(
              accountId: Value(accountId),
              note: Value(note),
              updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
            ));
        return changed == 1;
      });

  Future<void> softDeleteBill(String id) => transaction(() async {
        await _checkAaBillNotSettled(id);
        await (update(bills)..where((t) => t.id.equals(id))).write(
            BillsCompanion(
                deletedAt: Value(DateTime.now().millisecondsSinceEpoch)));
      });

  /// 撤销软删除（回收站/左滑撤销用）
  Future<void> restoreBill(String id) =>
      (update(bills)..where((t) => t.id.equals(id)))
          .write(BillsCompanion(deletedAt: Value<int?>(null)));

  /// 查重：同类型、同金额、同一自然日的未删除账单（排除指定 id，编辑时排除自身）
  Future<List<Bill>> findSimilarBills({
    required int type,
    required int amount,
    required int dateMs,
    String? excludeId,
  }) async {
    final d = DateTime.fromMillisecondsSinceEpoch(dateMs);
    final start = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
    final end =
        DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch;
    final rows = await (select(bills)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.type.equals(type) &
              t.amount.equals(amount) &
              t.dateMs.isBetweenValues(start, end - 1)))
        .get();
    return rows.where((b) => b.id != excludeId).toList();
  }

  Future<void> upsertAccount({
    required String id,
    required String name,
    required String emoji,
    required int type,
    required int initBalance,
    required bool includeNetWorth,
    required int sort,
  }) =>
      into(accounts).insertOnConflictUpdate(AccountsCompanion(
        id: Value(id),
        name: Value(name),
        emoji: Value(emoji),
        type: Value(type),
        initBalance: Value(initBalance),
        includeNetWorth: Value(includeNetWorth),
        sort: Value(sort),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));

  Future<void> deleteAccount(String id) =>
      (delete(accounts)..where((t) => t.id.equals(id))).go();

  Future<int> billCountOfAccount(String accountId) async {
    final rows = await (select(bills)
          ..where((t) =>
              t.deletedAt.isNull() &
              (t.accountId.equals(accountId) |
                  t.toAccountId.equals(accountId))))
        .get();
    return rows.length;
  }

  // ---------- AA 分摊（M2） ----------

  Stream<List<AaGroup>> watchAaGroups() => (select(aaGroups)
        ..orderBy([
          (t) => OrderingTerm.desc(t.dateMs),
          (t) => OrderingTerm.desc(t.createdAtMs),
        ]))
      .watch();

  Future<List<AaGroup>> getAllAaGroups() => select(aaGroups).get();

  Future<AaGroup?> getAaGroup(String id) =>
      (select(aaGroups)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsertAaGroup(AaGroupsCompanion c) =>
      into(aaGroups).insertOnConflictUpdate(c);

  /// 只核销本次结算快照明确覆盖的分摊组，消费日期不影响覆盖范围。
  Future<void> markGroupsSettled(
      List<String> ids, String settlementId, int updatedAtMs) {
    if (ids.isEmpty) return Future<void>.value();
    return (update(aaGroups)..where((t) => t.id.isIn(ids)))
        .write(AaGroupsCompanion(
      settled: const Value(true),
      settlementId: Value(settlementId),
      updatedAtMs: Value(updatedAtMs),
    ));
  }

  /// 将 cutoffMs 及之前、可结算（未结算且非挂起/取消）的分摊组标记为已结算
  Future<void> markSettledUpTo(int cutoffMs, String settlementId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (update(aaGroups)
          ..where((t) =>
              t.settled.equals(false) &
              t.status.isSmallerOrEqualValue(1) &
              t.dateMs.isSmallerOrEqualValue(cutoffMs)))
        .write(AaGroupsCompanion(
      settled: const Value(true),
      settlementId: Value(settlementId),
      updatedAtMs: Value(now),
    ));
  }

  /// 取消 AA 标记：关联账单转普通账单（isAa/aaGroupId 清空）
  Future<void> unlinkBillFromAaGroup(String billId) =>
      (update(bills)..where((t) => t.id.equals(billId))).write(BillsCompanion(
          isAa: const Value(false), aaGroupId: const Value<String?>(null)));

  /// 份额口径统一：AA 关联的份额类账单（非垫付方全额账单）金额 = 总额的一半（向下取整），
  /// 奇数总额多出的 1 分归垫付方。幂等，供 beforeOpen 修复历史数据。
  Future<void> normalizeAaShareAmounts() async {
    final groups = await select(aaGroups).get();
    for (final g in groups) {
      final share = g.totalAmount ~/ 2;
      final linked = await billsOfAaGroup(g.id);
      for (final b in linked) {
        // 垫付方的全额支出账单保持全额
        if (b.type == 0 && b.amount == g.totalAmount) continue;
        if (b.amount != share) await updateBillAmount(b.id, share);
      }
    }
  }

  // ---------- 结算（M2） ----------

  Stream<List<Settlement>> watchSettlements() => (select(settlements)
        ..orderBy([(t) => OrderingTerm.desc(t.dateMs)]))
      .watch();

  Future<List<Settlement>> getAllSettlements() => select(settlements).get();

  Future<Settlement?> getSettlement(String id) =>
      (select(settlements)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsertSettlement(SettlementsCompanion c) =>
      into(settlements).insertOnConflictUpdate(c);

  Future<bool> hasSettlementBill(String settlementId) async {
    final r = await (select(bills)
          ..where((t) => t.settlementId.equals(settlementId))
          ..limit(1))
        .getSingleOrNull();
    return r != null;
  }

  /// 某笔结算覆盖的分摊组（结算明细「AA平分：结算」逐条展示用）
  Future<List<AaGroup>> groupsOfSettlement(String settlementId) =>
      (select(aaGroups)..where((t) => t.settlementId.equals(settlementId)))
          .get();

  // ---------- 键值存储（配对信息 / 同步时间） ----------

  Stream<List<MetaEntry>> watchMeta() => select(metaEntries).watch();

  Future<String?> getMeta(String key) async {
    final r = await (select(metaEntries)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return r?.value;
  }

  Future<void> setMeta(String key, String value) =>
      into(metaEntries)
          .insertOnConflictUpdate(MetaEntriesCompanion(
              key: Value(key), value: Value(value)));

  Future<void> deleteMeta(String key) =>
      (delete(metaEntries)..where((t) => t.key.equals(key))).go();

  // ---------- 通用辅助 ----------

  Future<List<Account>> getAllAccounts() => select(accounts).get();

  Future<Account?> getAccount(String id) =>
      (select(accounts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<Category>> getAllCategories() => select(categories).get();

  Future<List<Bill>> getAllBills() =>
      (select(bills)..where((t) => t.deletedAt.isNull())).get();

  Future<List<Bill>> billsOfAaGroup(String groupId) => (select(bills)
        ..where((t) => t.deletedAt.isNull() & t.aaGroupId.equals(groupId)))
      .get();

  Future<void> updateBillAmount(String billId, int amount) =>
      (update(bills)..where((t) => t.id.equals(billId))).write(BillsCompanion(
          amount: Value(amount),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch)));

  Future<void> updateBillAmountAndDate(
          String billId, int amount, int dateMs) =>
      (update(bills)..where((t) => t.id.equals(billId))).write(BillsCompanion(
          amount: Value(amount),
          dateMs: Value(dateMs),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch)));

  /// 已关联到 AA 分摊组的账单 id 集合（流式，供「待入账」计算）
  Stream<Set<String>> watchLinkedAaGroupIds() => customSelect(
        'SELECT DISTINCT aa_group_id FROM bills WHERE deleted_at IS NULL AND aa_group_id IS NOT NULL',
        readsFrom: {bills},
      ).watch().map((rows) => {for (final r in rows) r.read<String>('aa_group_id')});

  /// 测试后门：清空所有账单与 AA 数据（保留账户/分类/配对），用于测试重置
  Future<void> deleteAllBillsAndAa() async {
    await (delete(bills)).go();
    await (delete(aaGroups)).go();
    await (delete(settlements)).go();
  }

  // ---------- 分类自定义 ----------

  Future<void> upsertCategory({
    required String id,
    required String name,
    required String emoji,
    required int kind,
    required int sort,
    bool isPreset = false,
    String? parentId,
  }) => transaction(() async {
      final cleanName = name.trim();
      if (id.isEmpty || cleanName.isEmpty) {
        throw StateError('请填写分类名称');
      }
      if (cleanName.contains(' / ')) {
        throw StateError('分类名称不能包含路径分隔符「 / 」');
      }
      if (kind < 0 || kind > 2) throw StateError('分类类型无效');
      final all = await getAllCategories();
      final byId = {for (final c in all) c.id: c};
      final current = byId[id];
      // 现有分类本版不可移动；省略父级时保留旧值。
      final effectiveParent = parentId ?? current?.parentId;
      if (current != null &&
          (current.kind != kind || effectiveParent != current.parentId)) {
        throw StateError('已有分类不能更换类型或父级');
      }
      if (effectiveParent != null) {
        final parent = byId[effectiveParent];
        if (effectiveParent == id || kind == 2 || parent == null ||
            parent.parentId != null || parent.kind != kind) {
          throw StateError('二级分类必须属于同类型的有效一级分类');
        }
      }
      if (all.any((c) => c.id != id && c.kind == kind &&
          c.parentId == effectiveParent && c.name.trim() == cleanName)) {
        throw StateError('同级已有同名分类');
      }
      await into(categories).insertOnConflictUpdate(CategoriesCompanion(
        id: Value(id),
        name: Value(cleanName),
        emoji: Value(emoji),
        kind: Value(kind),
        sort: Value(sort),
        isPreset: Value(isPreset),
        parentId: Value(effectiveParent),
      ));
    });

  Future<void> deleteCategory(String id) => transaction(() async {
    final children = await (select(categories)
          ..where((t) => t.parentId.equals(id))..limit(1)).get();
    if (children.isNotEmpty) throw StateError('请先删除该分类下的二级分类');
    final references = await (select(bills)
          ..where((t) => t.categoryId.equals(id))..limit(1)).get();
    if (references.isNotEmpty) {
      throw StateError('该分类仍有账单引用（含已删除账单），可改名继续使用');
    }
    await (delete(categories)..where((t) => t.id.equals(id))).go();
  });

  Future<int> billCountOfCategory(String categoryId) async {
    final rows = await (select(bills)
          ..where((t) => t.categoryId.equals(categoryId)))
        .get();
    return rows.length;
  }

  /// ids 必须是同类型、同父级的完整分类列表，事务内仅改变该级排序。
  Future<void> reorderCategories(List<String> ids) => transaction(() async {
    if (ids.isEmpty) return;
    final all = await getAllCategories();
    final byId = {for (final c in all) c.id: c};
    final first = byId[ids.first];
    if (first == null || ids.toSet().length != ids.length ||
        ids.any((id) => byId[id] == null || byId[id]!.kind != first.kind ||
            byId[id]!.parentId != first.parentId)) {
      throw StateError('只能对同级分类排序，请刷新后重试');
    }
    final siblings = all.where((c) =>
        c.kind == first.kind && c.parentId == first.parentId);
    if (siblings.length != ids.length) {
      throw StateError('分类列表已变化，请刷新后重试');
    }
    for (var i = 0; i < ids.length; i++) {
      await (update(categories)..where((t) => t.id.equals(ids[i])))
          .write(CategoriesCompanion(sort: Value(i)));
    }
  });
}
