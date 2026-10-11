import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/currency.dart';
import 'presets.dart';

part 'app_database.g.dart';

/// 删除确认窗口的完整快照；范围不包含二级源的父级，列表不可修改。
class CategoryDeletePreview {
  CategoryDeletePreview._({
    required this.sourceId,
    required List<Category> categories,
    required List<Bill> bills,
    this._sourceParent,
  }) : categories = List<Category>.unmodifiable(categories),
       bills = List<Bill>.unmodifiable(bills);

  final String sourceId;
  final List<Category> categories;
  final List<Bill> bills;
  final Category? _sourceParent;

  int get activeBillCount => bills.where((b) => b.deletedAt == null).length;
  int get deletedBillCount => bills.length - activeBillCount;
}

enum _CategoryDeleteDestinationKind { existing, create, uncategorized }

/// 删除分类时互斥的三个去向。已有二级及新建二级须提供父级快照。
class CategoryDeleteDestination {
  const CategoryDeleteDestination.existing(Category this.category, {this.parent})
      : _kind = _CategoryDeleteDestinationKind.existing,
        id = null,
        name = null,
        emoji = null;

  const CategoryDeleteDestination.create({
    required String this.id,
    required String this.name,
    required String this.emoji,
    this.parent,
  }) : _kind = _CategoryDeleteDestinationKind.create,
       category = null;

  const CategoryDeleteDestination.uncategorized()
      : _kind = _CategoryDeleteDestinationKind.uncategorized,
        category = null,
        parent = null,
        id = null,
        name = null,
        emoji = null;

  final _CategoryDeleteDestinationKind _kind;
  final Category? category;
  final Category? parent;
  final String? id;
  final String? name;
  final String? emoji;
}

/// 账户：type 0 现金 / 1 银行卡 / 2 信用卡 / 3 虚拟(微信/支付宝) / 4 AA挂账(M2)
class Accounts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get emoji => text().withDefault(const Constant('💰'))();
  IntColumn get type => integer().withDefault(const Constant(3))();
  IntColumn get initBalance => integer().withDefault(const Constant(0))(); // 分
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  BoolColumn get includeNetWorth =>
      boolean().withDefault(const Constant(true))();
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
/// amount 为交易币种最小单位；accountAmount 为账户币种实际收付款最小单位。
/// 转账 currency 固定为出账币种，amount == accountAmount；
/// toAccountAmount 为转入账户币种的实际入账额，普通收支为空。AA 协议暂限 CNY。
class Bills extends Table {
  TextColumn get id => text()();
  IntColumn get type => integer()();
  IntColumn get amount => integer()();
  TextColumn get currency => text().withDefault(const Constant('CNY'))();
  IntColumn get accountAmount => integer().withDefault(const Constant(0))();
  IntColumn get toAccountAmount => integer().nullable()();
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
  tables: [Accounts, Categories, Bills, AaGroups, Settlements, MetaEntries],
)
class AppDatabase extends _$AppDatabase {
  /// [executor] 仅供测试注入（如 NativeDatabase.memory()），生产路径不变
  AppDatabase({QueryExecutor? executor}) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) => transaction(() async {
      if (from == 1) {
        await m.createTable(aaGroups);
        await m.createTable(settlements);
        await m.createTable(metaEntries);
        await m.addColumn(bills, bills.settlementId);
      } else if (from == 2) {
        await m.addColumn(aaGroups, aaGroups.statusNote);
      }
      if (from < 4) {
        await m.addColumn(accounts, accounts.currency);
        await m.addColumn(bills, bills.currency);
        await m.addColumn(bills, bills.accountAmount);
        // Includes deleted rows, transfers and AA. Existing cents already
        // are CNY minor units: never rescale them or change timestamps.
        await customStatement('UPDATE bills SET account_amount = amount');
      }
      if (from < 5) {
        await m.addColumn(bills, bills.toAccountAmount);
        // Only unambiguous ordinary same-currency transfers can inherit a
        // credit amount. Include deleted rows without changing old fields.
        // Missing/foreign/AA historical references stay null: never guess FX.
        await customStatement('''
UPDATE bills SET to_account_amount = account_amount
WHERE type = 2 AND amount >= 0 AND amount = account_amount
  AND is_aa = 0 AND aa_group_id IS NULL AND settlement_id IS NULL
  AND currency IN ('CNY', 'USD', 'HKD', 'EUR', 'JPY', 'GBP')
  AND NOT EXISTS (
    SELECT 1 FROM categories
    WHERE categories.id = bills.category_id AND categories.kind = 2
  )
  AND EXISTS (
    SELECT 1 FROM accounts AS source, accounts AS target
    WHERE source.id = bills.account_id AND target.id = bills.to_account_id
      AND source.id <> target.id
      AND source.type <> 4 AND target.type <> 4
      AND source.id <> 'acc_aa_credit' AND target.id <> 'acc_aa_credit'
      AND source.currency = bills.currency AND target.currency = bills.currency
  )
''');
      }
    }),
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
    String? currency,
    int? accountAmount,
    int? toAccountAmount,
  }) => transaction(() async {
    await _checkAaBillNotSettled(id);
    final current = await (select(
      bills,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (current?.settlementId != null) {
      throw StateError('结算账单仅可修改本机账户和备注');
    }
    // 普通写入不能把既有关联清空后再作为外币账单改写。
    // 取消 AA 由专用事务先取消共享组，再 unlink 原始账单。
    if (current != null &&
        ((current.aaGroupId != null && current.aaGroupId != aaGroupId) ||
            (current.isAa && aaGroupId == null))) {
      throw StateError('账单 AA 或结算关联已存在，不能清空或更换');
    }
    final account = await getAccount(accountId);
    if (account == null) throw StateError('所选账户不存在，请重新选择');
    _currencyCode(account.currency);
    final code = _currencyCode(
      currency ?? (type == 2 ? account.currency : current?.currency ?? 'CNY'),
    );
    if (type < 0 || type > 3 || (type != 3 && amount < 0)) {
      throw StateError('账单类型或金额无效');
    }
    final identityChanged = current != null &&
        (current.currency != code || current.amount != amount ||
            current.accountId != accountId);
    if (identityChanged && accountAmount == null) {
      final previousAccount = await getAccount(current.accountId);
      if (previousAccount?.currency != current.currency) {
        throw StateError('跨币种账单金额或账户变化，请重新确认实际收付款额');
      }
    }
    final sameCurrency = code == account.currency;
    final int actual;
    if (sameCurrency) {
      actual = accountAmount ?? amount;
      if (actual != amount) throw StateError('同币种交易的原币与账户金额必须一致');
    } else {
      final unchanged =
          current != null &&
          current.currency == code &&
          current.amount == amount &&
          current.accountId == accountId;
      final retained = unchanged ? current.accountAmount : null;
      final supplied = accountAmount ?? retained;
      if (supplied == null) throw StateError('跨币种交易请填写账户实际收付款额');
      actual = supplied;
    }
    if (type != 3 && actual < 0) throw StateError('账户实际收付款额无效');
    int? incoming;
    if (type == 2) {
      final target = toAccountId == null ? null : await getAccount(toAccountId);
      if (target == null || target.id == accountId) {
        throw StateError('请选择不同且有效的转入账户');
      }
      _currencyCode(target.currency);
      if (!sameCurrency || amount != actual) {
        throw StateError('转账币种与金额必须采用出账账户的实际出账额');
      }
      if (account.type == 4 ||
          target.type == 4 ||
          account.id == kAaCreditAccountId ||
          target.id == kAaCreditAccountId ||
          aaGroupId != null ||
          settlementId != null ||
          current?.isAa == true ||
          current?.aaGroupId != null ||
          current?.settlementId != null) {
        throw StateError('转账不能关联 AA、结算或使用 AA 挂账账户');
      }
      final transferUnchanged = current != null &&
          current.type == type &&
          current.accountId == accountId &&
          current.toAccountId == toAccountId &&
          current.currency == code &&
          current.amount == amount &&
          current.accountAmount == actual;
      if (current != null && current.type == 2 &&
          !transferUnchanged && toAccountAmount == null) {
        final previousTarget = current.toAccountId == null
            ? null
            : await getAccount(current.toAccountId!);
        if (previousTarget?.currency != current.currency) {
          throw StateError('跨币种转账账户或金额变化，请重新确认入账金额');
        }
      }
      if (target.currency == code) {
        incoming = toAccountAmount ?? actual;
        if (incoming != actual) {
          throw StateError('同币种转账的出账与入账金额必须一致');
        }
      } else {
        incoming = toAccountAmount ?? (transferUnchanged ? current.toAccountAmount : null);
        if (actual <= 0 || incoming == null || incoming <= 0) {
          throw StateError('跨币种转账请分别确认大于零的出账和入账金额');
        }
      }
    } else if (toAccountId != null || toAccountAmount != null) {
      throw StateError('仅转账可指定转入账户和入账金额');
    }
    if (categoryId != null) {
      final category = await (select(
        categories,
      )..where((t) => t.id.equals(categoryId))).getSingleOrNull();
      if (category == null) {
        throw StateError('所选分类已删除，请重新选择');
      }
      if (type == 2 && category.kind == 2) {
        throw StateError('转账不能使用 AA 内部往来分类');
      }
      if (category.kind == 2) _checkCnyMoney(code, account, amount, actual);
    }
    if (aaGroupId != null ||
        settlementId != null ||
        current?.isAa == true ||
        current?.aaGroupId != null ||
        current?.settlementId != null ||
        account.type == 4 ||
        account.id == kAaCreditAccountId) {
      _checkCnyMoney(code, account, amount, actual);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await into(bills).insertOnConflictUpdate(
      BillsCompanion(
        id: Value(id),
        type: Value(type),
        amount: Value(amount),
        currency: Value(code),
        accountAmount: Value(actual),
        toAccountAmount: Value(incoming),
        categoryId: Value(categoryId),
        accountId: Value(accountId),
        toAccountId: Value(toAccountId),
        dateMs: Value(dateMs),
        note: Value(note),
        isAa: Value(aaGroupId != null),
        aaGroupId: Value(aaGroupId),
        settlementId: Value(settlementId),
        createdAt: Value(createdAt ?? current?.createdAt ?? now),
        updatedAt: Value(now),
      ),
    );
  });

  static String _currencyCode(String code) {
    final currency = Currency.tryFromCode(code);
    if (currency == null) throw StateError('不支持的币种');
    return currency.code;
  }

  static void _checkCnyMoney(
    String code,
    Account account,
    int amount,
    int actual,
  ) {
    if (code != 'CNY' || account.currency != 'CNY' || actual != amount) {
      throw StateError('AA 与结算暂仅支持 CNY 交易和 CNY 账户');
    }
  }

  Future<void> linkBillToAaGroup(String billId, String groupId) =>
      transaction(() async {
        await _checkAaBillNotSettled(billId);
        final bill = await (select(
          bills,
        )..where((t) => t.id.equals(billId))).getSingleOrNull();
        if (bill == null ||
            bill.deletedAt != null ||
            bill.type != 0 ||
            bill.toAccountId != null ||
            bill.settlementId != null) {
          throw StateError('仅有效支出可关联 AA');
        }
        if ((bill.aaGroupId != null && bill.aaGroupId != groupId) ||
            (bill.isAa && bill.aaGroupId == null)) {
          throw StateError('账单已关联 AA，不能更换分摊组');
        }
        final account = await getAccount(bill.accountId);
        if (account == null) throw StateError('所选账户不存在');
        _checkCnyMoney(bill.currency, account, bill.amount, bill.accountAmount);
        await (update(bills)..where((t) => t.id.equals(billId))).write(
          BillsCompanion(isAa: const Value(true), aaGroupId: Value(groupId)),
        );
      });

  /// 结算收支仅改本机字段，不用页面快照重写金额或结算关联。
  Future<bool> updateSettlementBillLocalFields({
    required String billId,
    required String settlementId,
    required String accountId,
    required String note,
  }) => transaction(() async {
    if (accountId == kAaCreditAccountId) return false;
    final account = await (select(
      accounts,
    )..where((t) => t.id.equals(accountId))).getSingleOrNull();
    if (account == null || account.type == 4 || account.currency != 'CNY') {
      return false;
    }
    final current = await (select(
      bills,
    )..where((t) => t.id.equals(billId))).getSingleOrNull();
    if (current == null ||
        current.currency != 'CNY' ||
        current.accountAmount != current.amount) {
      return false;
    }
    final changed =
        await (update(bills)..where(
              (t) =>
                  t.id.equals(billId) &
                  t.deletedAt.isNull() &
                  t.settlementId.equals(settlementId) &
                  t.aaGroupId.isNull() &
                  t.type.isIn([0, 1]),
            ))
            .write(
              BillsCompanion(
                accountId: Value(accountId),
                note: Value(note),
                updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
              ),
            );
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

  /// 查重：同交易币种、同类型、同原币金额、同一自然日的未删除账单。
  /// 旧调用默认人民币；账户实际额不用于跨币账单查重。
  Future<List<Bill>> findSimilarBills({
    required int type,
    required int amount,
    required int dateMs,
    String? excludeId,
    String currency = 'CNY',
  }) async {
    final code = _currencyCode(currency);
    final d = DateTime.fromMillisecondsSinceEpoch(dateMs);
    final start = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
    final end =
        DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch;
    final rows = await (select(bills)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.currency.equals(code) &
              t.type.equals(type) &
              t.amount.equals(amount) &
              t.dateMs.isBiggerOrEqualValue(start) &
              t.dateMs.isSmallerThanValue(end)))
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
    String? currency,
    Account? expected,
  }) => transaction(() async {
    final current = await getAccount(id);
    if (expected != null && current != expected) {
      throw StateError('账户已变化，请关闭后重新打开');
    }
    final code = _currencyCode(currency ?? current?.currency ?? 'CNY');
    if ((type == 4 || id == kAaCreditAccountId) && code != 'CNY') {
      throw StateError('AA 挂账账户仅支持 CNY');
    }
    if (current != null && code != current.currency) {
      final reference =
          await (select(bills)
                ..where(
                  (t) => t.accountId.equals(id) | t.toAccountId.equals(id),
                )
                ..limit(1))
              .getSingleOrNull();
      if (reference != null) throw StateError('账户已有账单引用，不能修改币种');
    }
    await into(accounts).insertOnConflictUpdate(
      AccountsCompanion(
        id: Value(id),
        name: Value(name),
        emoji: Value(emoji),
        type: Value(type),
        initBalance: Value(initBalance),
        currency: Value(code),
        includeNetWorth: Value(includeNetWorth),
        sort: Value(sort),
        createdAt: Value(
          current?.createdAt ?? DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
  });

  Future<void> deleteAccount(String id) => transaction(() async {
    if (id == kAaCreditAccountId) {
      throw StateError('AA 挂账固定账户不能删除');
    }
    final reference = await (select(bills)
          ..where((t) => t.accountId.equals(id) | t.toAccountId.equals(id))
          ..limit(1))
        .getSingleOrNull();
    if (reference != null) {
      throw StateError('该账户仍有账单引用（含已删除账单），无法删除');
    }
    await (delete(accounts)..where((t) => t.id.equals(id))).go();
  });

  Future<int> billCountOfAccount(String accountId,
      {bool includeDeleted = false}) async {
    final query = select(bills)
      ..where((t) => t.accountId.equals(accountId) |
          t.toAccountId.equals(accountId));
    if (!includeDeleted) query.where((t) => t.deletedAt.isNull());
    return (await query.get()).length;
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
      transaction(() async {
        await _checkAaBillNotSettled(billId);
        await (update(bills)..where((t) => t.id.equals(billId))).write(
          BillsCompanion(
            isAa: const Value(false),
            aaGroupId: const Value<String?>(null),
          ),
        );
      });

  /// 份额口径统一：AA 关联的份额类账单（非垫付方全额账单）金额 = 总额的一半（向下取整），
  /// 奇数总额多出的 1 分归垫付方。幂等，供 beforeOpen 修复历史数据。
  Future<void> normalizeAaShareAmounts() async {
    final groups = await select(aaGroups).get();
    for (final g in groups) {
      // 历史结算金额必须保留，开库修复不能绕过用户写入防护。
      if (g.settled || g.settlementId != null) continue;
      final share = g.totalAmount ~/ 2;
      final linked = await billsOfAaGroup(g.id);
      for (final b in linked) {
        final account = await getAccount(b.accountId);
        // Do not let malformed historical associations block opening the app
        // or overwrite a foreign amount through a CNY-only repair helper.
        if ((b.type != 0 && b.type != 1) ||
            b.settlementId != null ||
            b.currency != 'CNY' ||
            account?.currency != 'CNY' ||
            b.accountAmount != b.amount) {
          continue;
        }
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
      _updateCnyBillAmount(billId, amount);

  Future<void> updateBillAmountAndDate(String billId, int amount, int dateMs) =>
      _updateCnyBillAmount(billId, amount, dateMs: dateMs);

  Future<void> _updateCnyBillAmount(String billId, int amount, {int? dateMs}) =>
      transaction(() async {
        await _checkAaBillNotSettled(billId);
        final bill = await (select(
          bills,
        )..where((t) => t.id.equals(billId))).getSingleOrNull();
        if (bill == null) return;
        if (bill.settlementId != null) {
          throw StateError('结算账单仅可修改本机账户和备注');
        }
        final account = await getAccount(bill.accountId);
        if (account == null || amount < 0) throw StateError('账户或金额无效');
        _checkCnyMoney(bill.currency, account, bill.amount, bill.accountAmount);
        if (bill.type == 2) {
          if (bill.isAa || bill.aaGroupId != null || bill.settlementId != null) {
            throw StateError('快捷转账更新不能改动 AA 或结算记录');
          }
          final target = bill.toAccountId == null
              ? null
              : await getAccount(bill.toAccountId!);
          if (target == null || target.id == account.id || target.currency != 'CNY' ||
              target.type == 4 || target.id == kAaCreditAccountId || account.type == 4 ||
              account.id == kAaCreditAccountId) {
            throw StateError('快捷金额更新仅支持真实人民币账户间的同币种转账');
          }
        }
        await (update(bills)..where((t) => t.id.equals(billId))).write(
          BillsCompanion(
            amount: Value(amount),
            accountAmount: Value(amount),
            toAccountAmount: bill.type == 2 ? Value(amount) : const Value.absent(),
            dateMs: dateMs == null ? const Value.absent() : Value(dateMs),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
      });

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
    Category? expected,
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
      if (expected != null && current != expected) {
        throw StateError('分类已变化，请关闭后重新打开');
      }
      // 普通编辑不改变归属；迁移二级分类须调用 moveSubcategory。
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

  /// 迁移有效二级分类，仅改变父级与目标同级排序，保留全部账单引用。
  Future<void> moveSubcategory({
    required String id,
    required String expectedParentId,
    required String targetParentId,
  }) => transaction(() async {
    final all = await getAllCategories();
    final byId = {for (final c in all) c.id: c};
    final current = byId[id];
    if (current == null || current.parentId == null ||
        (current.kind != 0 && current.kind != 1)) {
      throw StateError('只能迁移支出或收入的有效二级分类');
    }
    if (current.parentId != expectedParentId) {
      throw StateError('分类归属已变化，请刷新后重试');
    }
    final sourceParent = byId[current.parentId];
    if (sourceParent == null || sourceParent.id == current.id ||
        sourceParent.parentId != null || sourceParent.kind != current.kind ||
        all.any((c) => c.parentId == id)) {
      throw StateError('分类归属异常，请刷新后重试');
    }
    final target = byId[targetParentId];
    if (target == null || target.id == id || target.parentId != null ||
        target.kind != current.kind) {
      throw StateError('目标必须是同类型的有效一级分类');
    }
    if (target.id == current.parentId) {
      throw StateError('请选择另一个一级分类');
    }
    final siblings = all.where((c) =>
        c.kind == current.kind && c.parentId == target.id);
    if (siblings.any((c) => c.name.trim() == current.name.trim())) {
      throw StateError('目标一级下已有同名二级分类');
    }
    final lastSort = siblings.fold<int>(
        -1, (value, c) => c.sort > value ? c.sort : value);
    if (lastSort == 0x7FFFFFFFFFFFFFFF) {
      throw StateError('目标排序已达到上限，请先重新排序后重试');
    }
    final changed = await (update(categories)
          ..where((t) => t.id.equals(id) &
              t.parentId.equals(expectedParentId)))
        .write(CategoriesCompanion(
          parentId: Value(target.id),
          sort: Value(lastSort + 1),
        ));
    if (changed != 1) throw StateError('分类归属已变化，请刷新后重试');
  });

  Future<CategoryDeletePreview> previewCategoryDeletion(String id) =>
      transaction(() => _readCategoryDeletePreview(id));

  Future<CategoryDeletePreview> _readCategoryDeletePreview(String id,
      {List<Category>? allCategories}) async {
    final all = allCategories ?? await getAllCategories();
    final byId = {for (final c in all) c.id: c};
    final source = byId[id];
    if (source == null) throw StateError('该分类已删除，请刷新后重试');
    if (source.kind != 0 && source.kind != 1) {
      throw StateError('仅支持删除支出或收入分类');
    }
    final children = all.where((c) => c.parentId == id).toList();
    Category? sourceParent;
    if (source.parentId != null) {
      sourceParent = byId[source.parentId];
      if (sourceParent == null || sourceParent.id == id ||
          sourceParent.parentId != null || sourceParent.kind != source.kind ||
          children.isNotEmpty) {
        throw StateError('分类归属异常，暂不能删除');
      }
    } else {
      final childIds = children.map((c) => c.id).toSet();
      if (children.any((c) => c.kind != source.kind) ||
          all.any((c) => childIds.contains(c.parentId))) {
        throw StateError('分类归属异常，暂不能删除');
      }
    }
    final scope = [source, ...children]
      ..sort((a, b) => a.id.compareTo(b.id));
    final scopeIds = scope.map((c) => c.id).toSet();
    final references = await (select(bills)
          ..where((t) => t.categoryId.isIn(scopeIds))
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    return CategoryDeletePreview._(
      sourceId: id,
      categories: scope,
      bills: references,
      sourceParent: sourceParent,
    );
  }

  bool _sameCategoryDeleteRows<T>(List<T> before, List<T> after) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      if (before[i] != after[i]) return false;
    }
    return true;
  }

  Category _categoryDeleteTargetParent(Category snapshot,
      Map<String, Category> byId, int kind, Set<String> deletingIds) {
    final parent = byId[snapshot.id];
    if (parent != snapshot) {
      throw StateError('目标一级已变化，请重新选择');
    }
    if (parent == null || parent.parentId != null || parent.kind != kind ||
        deletingIds.contains(parent.id)) {
      throw StateError('目标父级必须是同类型有效一级分类');
    }
    return parent;
  }

  Future<void> _checkCategoryDeleteBillsMutable(List<Bill> references) async {
    final groups = {for (final g in await getAllAaGroups()) g.id: g};
    for (final bill in references) {
      if (bill.settlementId != null) {
        throw StateError('结算账单分类不可更改，请保留该分类');
      }
      final groupId = bill.aaGroupId;
      if (groupId == null) {
        if (bill.isAa) throw StateError('账单 AA 关联异常，暂不能转移分类');
        continue;
      }
      final group = groups[groupId];
      if (group == null) throw StateError('账单 AA 关联异常，暂不能转移分类');
      if (group.settled || group.settlementId != null) {
        throw StateError('该 AA 账单已结算，不能再修改');
      }
      if (!bill.isAa) throw StateError('账单 AA 关联异常，暂不能转移分类');
      if (bill.type != 0) {
        throw StateError('AA 内部往来账单分类不可更改，请保留该分类');
      }
    }
  }

  /// 校验完整确认快照后原子转移引用并删除分类；账单只改 categoryId。
  /// 不更新历史时间、金额、AA 关联或同步快照，软删除引用也必须转移。
  Future<void> deleteCategoryAndReassign({
    required CategoryDeletePreview expected,
    required CategoryDeleteDestination destination,
    bool confirmWholeGroup = false,
  }) => transaction(() async {
    final all = await getAllCategories();
    final byId = {for (final c in all) c.id: c};
    final current = await _readCategoryDeletePreview(expected.sourceId,
        allCategories: all);
    if (!_sameCategoryDeleteRows(expected.categories, current.categories) ||
        !_sameCategoryDeleteRows(expected.bills, current.bills) ||
        expected._sourceParent != current._sourceParent) {
      throw StateError('分类或账单已变化，请重新确认删除范围');
    }
    if (current.categories.length > 1 && !confirmWholeGroup) {
      throw StateError('请明确确认删除一级及其全部二级分类');
    }
    await _checkCategoryDeleteBillsMutable(current.bills);
    final source = byId[current.sourceId]!;
    final deletingIds = current.categories.map((c) => c.id).toSet();
    String? targetId;
    CategoriesCompanion? newCategory;
    switch (destination._kind) {
      case _CategoryDeleteDestinationKind.uncategorized:
        targetId = null;
        break;
      case _CategoryDeleteDestinationKind.existing:
        final snapshot = destination.category!;
        final target = byId[snapshot.id];
        if (target != snapshot) {
          throw StateError('目标分类已变化，请重新选择');
        }
        if (target == null || target.kind != source.kind ||
            deletingIds.contains(target.id)) {
          throw StateError('目标必须是同类型且不在删除范围内的分类');
        }
        if (target.parentId == null) {
          if (destination.parent != null) {
            throw StateError('目标父级快照与分类归属不符，请重新选择');
          }
        } else {
          final parentSnapshot = destination.parent;
          if (parentSnapshot == null || parentSnapshot.id != target.parentId) {
            throw StateError('请选择二级目标的有效一级分类');
          }
          _categoryDeleteTargetParent(parentSnapshot, byId,
              source.kind, deletingIds);
        }
        targetId = target.id;
        break;
      case _CategoryDeleteDestinationKind.create:
        final id = destination.id!;
        final name = destination.name!.trim();
        if (id.trim().isEmpty) throw StateError('新分类 ID 无效');
        if (byId.containsKey(id)) {
          throw StateError('新分类 ID 已存在，请重新创建');
        }
        if (name.isEmpty) throw StateError('请填写分类名称');
        if (name.contains(' / ')) {
          throw StateError('分类名称不能包含路径分隔符「 / 」');
        }
        String? parentId;
        final parentSnapshot = destination.parent;
        if (parentSnapshot != null) {
          parentId = _categoryDeleteTargetParent(parentSnapshot, byId,
              source.kind, deletingIds).id;
        }
        final siblings = all.where((c) =>
            c.kind == source.kind && c.parentId == parentId);
        if (siblings.any((c) => c.name.trim() == name)) {
          throw StateError('同级已有同名分类');
        }
        final lastSort = siblings.fold<int>(
            -1, (value, c) => c.sort > value ? c.sort : value);
        if (lastSort == 0x7FFFFFFFFFFFFFFF) {
          throw StateError('目标排序已达到上限，请先重新排序后重试');
        }
        newCategory = CategoriesCompanion.insert(
          id: id,
          name: name,
          emoji: destination.emoji!,
          kind: source.kind,
          parentId: Value(parentId),
          sort: Value(lastSort + 1),
          isPreset: const Value(false),
        );
        targetId = id;
        break;
    }
    if (newCategory != null) await into(categories).insert(newCategory);
    final changed = await (update(bills)
          ..where((t) => t.categoryId.isIn(deletingIds)))
        .write(BillsCompanion(categoryId: Value<String?>(targetId)));
    if (changed != current.bills.length) {
      throw StateError('分类账单已变化，请重新确认删除范围');
    }
    final removed = await (delete(categories)
          ..where((t) => t.id.isIn(deletingIds)))
        .go();
    if (removed != current.categories.length) {
      throw StateError('分类已变化，请重新确认删除范围');
    }
    final remainingReference = await (select(bills)
          ..where((t) => t.categoryId.isIn(deletingIds))..limit(1))
        .getSingleOrNull();
    final remainingCategory = await (select(categories)
          ..where((t) => t.id.isIn(deletingIds))..limit(1))
        .getSingleOrNull();
    if (remainingReference != null || remainingCategory != null) {
      throw StateError('分类引用已变化，删除已回滚，请重新确认');
    }
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
