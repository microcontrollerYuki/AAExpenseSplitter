import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/category_hierarchy.dart';

import '../helpers/test_support.dart';

Future<void> addCategory(
  AppDatabase db,
  String id,
  String name, {
  int kind = 0,
  String? parent,
  int sort = 0,
  bool preset = false,
}) => db.upsertCategory(
  id: id,
  name: name,
  emoji: '☕',
  kind: kind,
  parentId: parent,
  sort: sort,
  isPreset: preset,
);

Future<void> seedMove(AppDatabase db, {int kind = 0}) async {
  await addCategory(db, 'from', '原一级', kind: kind, sort: -3);
  await addCategory(db, 'to', '新一级', kind: kind, sort: -2);
  await addCategory(db, 'third', '另一一级', kind: kind, sort: -1);
  await addCategory(
    db,
    'moving',
    '待迁移二级',
    kind: kind,
    parent: 'from',
    sort: 7,
    preset: true,
  );
}

Future<Map<String, Object?>> categoryRows(AppDatabase db) async => {
  for (final c in await db.getAllCategories()) c.id: c.toJson(),
};

Future<Map<String, Object?>> businessRows(AppDatabase db) async => {
  'accounts': {
    for (final row in await db.select(db.accounts).get()) row.id: row.toJson(),
  },
  'bills': {
    for (final row in await db.select(db.bills).get()) row.id: row.toJson(),
  },
  'aaGroups': {
    for (final row in await db.select(db.aaGroups).get()) row.id: row.toJson(),
  },
  'settlements': {
    for (final row in await db.select(db.settlements).get())
      row.id: row.toJson(),
  },
};

Future<void> rawCategory(
  AppDatabase db,
  String id, {
  required String parent,
  int kind = 0,
}) => db
    .into(db.categories)
    .insert(
      CategoriesCompanion.insert(
        id: id,
        name: id,
        emoji: '📦',
        kind: kind,
        parentId: Value(parent),
      ),
    );

void main() {
  late AppDatabase db;
  setUp(() async {
    db = TestAppDatabase();
    await db.getAllAccounts();
  });
  tearDown(() => db.close());

  for (final kind in [0, 1]) {
    test('类型 $kind 二级迁到目标末尾，仅改变其父级和排序', () async {
      await seedMove(db, kind: kind);
      await addCategory(
        db,
        'source-peer',
        '原同级',
        kind: kind,
        parent: 'from',
        sort: 19,
      );
      await addCategory(
        db,
        'target-a',
        '目标甲',
        kind: kind,
        parent: 'to',
        sort: 4,
      );
      await addCategory(
        db,
        'target-b',
        '目标乙',
        kind: kind,
        parent: 'to',
        sort: 20,
      );
      final before = await categoryRows(db);

      await db.moveSubcategory(
        id: 'moving',
        expectedParentId: 'from',
        targetParentId: 'to',
      );

      final after = await categoryRows(db);
      expect(after['moving'], {
        ...before['moving'] as Map<String, dynamic>,
        'parentId': 'to',
        'sort': 21,
      });
      for (final id in before.keys.where((id) => id != 'moving')) {
        expect(after[id], before[id]);
      }
      final tree = CategoryHierarchy(await db.getAllCategories());
      expect(tree.pathOf('moving'), '新一级 / 待迁移二级');
      expect(tree.childrenOf('to').map((c) => c.id), [
        'target-a',
        'target-b',
        'moving',
      ]);
    });
  }

  test('迁移不重写普通、软删除、AA、已结算账单及历史同步快照', () async {
    await seedMove(db);
    await db.upsertSettlement(
      SettlementsCompanion.insert(
        id: 'settlement',
        receiverUid: 'partner',
        amount: 567,
        dateMs: 400,
        cutoffMs: 300,
        createdAtMs: 401,
      ),
    );
    await db.upsertAaGroup(
      AaGroupsCompanion.insert(
        id: 'aa-group',
        ownerUid: 'owner',
        payerUid: 'partner',
        totalAmount: 1134,
        dateMs: 123,
        note: const Value('同步备注'),
        categoryName: const Value('原一级 / 待迁移二级'),
        categoryEmoji: const Value('☕'),
        status: const Value(1),
        settled: const Value(true),
        settlementId: const Value('settlement'),
        createdAtMs: 124,
        updatedAtMs: 125,
      ),
    );
    for (final id in ['normal', 'deleted', 'aa', 'settlement-bill']) {
      await db.upsertBill(
        id: id,
        type: 0,
        amount: 567,
        categoryId: 'moving',
        accountId: 'acc_wechat',
        dateMs: 123,
        note: '账单备注 $id',
        createdAt: 124,
        aaGroupId: id == 'aa' ? 'aa-group' : null,
        settlementId: id == 'settlement-bill' ? 'settlement' : null,
      );
    }
    await db.softDeleteBill('deleted');
    final before = await businessRows(db);

    await db.moveSubcategory(
      id: 'moving',
      expectedParentId: 'from',
      targetParentId: 'to',
    );

    expect(await businessRows(db), before);
    expect(await db.billCountOfCategory('moving'), 4);
    expect(
      CategoryHierarchy(await db.getAllCategories()).pathOf('moving'),
      '新一级 / 待迁移二级',
    );
    await expectLater(
      db.upsertBill(
        id: 'aa',
        type: 0,
        amount: 1,
        accountId: 'acc_cash',
        dateMs: 1,
      ),
      throwsStateError,
    );
    expect(await businessRows(db), before);
  });

  test('缺失、一级、内部、孤儿、循环、跨类型父级、三级及带原始子引用源均拒绝', () async {
    await seedMove(db);
    await addCategory(db, 'income-root', '收入一级', kind: 1);
    await rawCategory(db, 'orphan', parent: 'ghost');
    await rawCategory(db, 'cycle', parent: 'cycle');
    await rawCategory(db, 'cross-parent', parent: 'income-root');
    await rawCategory(db, 'internal-child', parent: 'cat_aa_marker', kind: 2);
    await rawCategory(db, 'third-level', parent: 'moving');
    await addCategory(db, 'raw-parent', '有异常子引用', parent: 'from');
    await rawCategory(db, 'raw-child', parent: 'raw-parent', kind: 2);
    final before = await categoryRows(db);
    for (final attempt in [
      (id: 'ghost', parent: 'from'),
      (id: 'from', parent: 'third'),
      (id: 'orphan', parent: 'ghost'),
      (id: 'cycle', parent: 'cycle'),
      (id: 'cross-parent', parent: 'income-root'),
      (id: 'internal-child', parent: 'cat_aa_marker'),
      (id: 'third-level', parent: 'moving'),
      (id: 'moving', parent: 'from'),
      (id: 'raw-parent', parent: 'from'),
    ]) {
      await expectLater(
        db.moveSubcategory(
          id: attempt.id,
          expectedParentId: attempt.parent,
          targetParentId: 'to',
        ),
        throwsStateError,
      );
      expect(await categoryRows(db), before);
    }
  });

  test('缺失、跨类型、内部、二级、孤儿、循环、自身及原父级目标均拒绝', () async {
    await seedMove(db);
    await addCategory(db, 'income-root', '收入一级', kind: 1);
    await addCategory(db, 'target-child', '目标二级', parent: 'to');
    await rawCategory(db, 'orphan', parent: 'ghost');
    await rawCategory(db, 'cycle', parent: 'cycle');
    final before = await categoryRows(db);
    for (final target in [
      '',
      'ghost',
      'income-root',
      'cat_aa_marker',
      'target-child',
      'orphan',
      'cycle',
      'moving',
      'from',
    ]) {
      await expectLater(
        db.moveSubcategory(
          id: 'moving',
          expectedParentId: 'from',
          targetParentId: target,
        ),
        throwsStateError,
      );
      expect(await categoryRows(db), before);
    }
  });

  test('目标同级名称去空白重名拒绝，并按迁移时最新名称检查', () async {
    await seedMove(db);
    await addCategory(db, 'target-child', '新名称', parent: 'to');
    await (db.update(db.categories)..where((t) => t.id.equals('target-child')))
        .write(const CategoriesCompanion(name: Value('  新名称  ')));
    await addCategory(db, 'moving', '新名称', parent: 'from', sort: 7);
    final before = await categoryRows(db);
    await expectLater(
      db.moveSubcategory(
        id: 'moving',
        expectedParentId: 'from',
        targetParentId: 'to',
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', '目标一级下已有同名二级分类'),
      ),
    );
    expect(await categoryRows(db), before);
  });

  test('陈旧父级拒绝，普通 upsert 仍不允许迁移或跨类型', () async {
    await seedMove(db);
    await db.moveSubcategory(
      id: 'moving',
      expectedParentId: 'from',
      targetParentId: 'to',
    );
    final before = await categoryRows(db);
    await expectLater(
      db.moveSubcategory(
        id: 'moving',
        expectedParentId: 'from',
        targetParentId: 'third',
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', '分类归属已变化，请刷新后重试'),
      ),
    );
    await expectLater(
      addCategory(db, 'moving', '待迁移二级', parent: 'from'),
      throwsStateError,
    );
    await expectLater(
      addCategory(db, 'moving', '待迁移二级', kind: 1, parent: 'to'),
      throwsStateError,
    );
    expect(await categoryRows(db), before);
  });

  test('打开后目标或源被删除时拒绝，不重建分类或改动原归属', () async {
    await seedMove(db);
    await db.deleteCategory('to');
    final before = await categoryRows(db);
    await expectLater(
      db.moveSubcategory(
        id: 'moving',
        expectedParentId: 'from',
        targetParentId: 'to',
      ),
      throwsStateError,
    );
    expect(await categoryRows(db), before);
    await db.deleteCategory('moving');
    final withoutSource = await categoryRows(db);
    await expectLater(
      db.moveSubcategory(
        id: 'moving',
        expectedParentId: 'from',
        targetParentId: 'third',
      ),
      throwsStateError,
    );
    expect(await categoryRows(db), withoutSource);
  });

  test('空目标与负数排序追加到末尾，64 位排序上限原子拒绝', () async {
    await seedMove(db);
    await addCategory(db, 'negative-peer', '负数排序', parent: 'from', sort: -8);
    await db.moveSubcategory(
      id: 'moving',
      expectedParentId: 'from',
      targetParentId: 'to',
    );
    expect(
      (await db.getAllCategories()).singleWhere((c) => c.id == 'moving').sort,
      0,
    );
    await db.moveSubcategory(
      id: 'moving',
      expectedParentId: 'to',
      targetParentId: 'from',
    );
    final tree = CategoryHierarchy(await db.getAllCategories());
    expect(tree.childrenOf('from').map((c) => c.id), [
      'negative-peer',
      'moving',
    ]);
    await addCategory(
      db,
      'max-sort',
      '排序上限',
      parent: 'third',
      sort: 0x7FFFFFFFFFFFFFFF,
    );
    final before = await categoryRows(db);
    await expectLater(
      db.moveSubcategory(
        id: 'moving',
        expectedParentId: 'from',
        targetParentId: 'third',
      ),
      throwsStateError,
    );
    expect(await categoryRows(db), before);
  });

  test('并发旧归属不覆盖新归属，多项迁到同一目标保持末尾排序', () async {
    await seedMove(db);
    Future<Object> attempt(String target) => db
        .moveSubcategory(
          id: 'moving',
          expectedParentId: 'from',
          targetParentId: target,
        )
        .then<Object>((_) => target, onError: (Object e) => e);
    final results = await Future.wait([attempt('to'), attempt('third')]);
    final succeeded = results.whereType<String>().single;
    expect(results.whereType<StateError>(), hasLength(1));
    final current = (await db.getAllCategories()).singleWhere(
      (c) => c.id == 'moving',
    );
    expect(current.parentId, succeeded);
    expect(current.sort, 0);
    await addCategory(db, 'append-target', '并发追加目标');
    await addCategory(db, 'parallel-a', '并发甲', parent: 'from');
    await addCategory(db, 'parallel-b', '并发乙', parent: 'from');
    await Future.wait([
      for (final id in ['parallel-a', 'parallel-b'])
        db.moveSubcategory(
          id: id,
          expectedParentId: 'from',
          targetParentId: 'append-target',
        ),
    ]);
    final children = CategoryHierarchy(await db.getAllCategories())
        .childrenOf('append-target');
    expect(children.map((c) => c.id).toSet(), {'parallel-a', 'parallel-b'});
    expect(children.map((c) => c.sort).toSet(), {0, 1});
  });

  test('迁移后源与目标的旧排序请求均拒绝，其他排序保持不变', () async {
    await seedMove(db);
    await addCategory(db, 'source-peer', '原同级', parent: 'from', sort: 19);
    await addCategory(db, 'target-peer', '目标同级', parent: 'to', sort: 29);
    await db.moveSubcategory(
      id: 'moving',
      expectedParentId: 'from',
      targetParentId: 'to',
    );
    final before = await categoryRows(db);
    for (final oldList in [
      ['moving', 'source-peer'],
      ['target-peer'],
    ]) {
      await expectLater(db.reorderCategories(oldList), throwsStateError);
      expect(await categoryRows(db), before);
    }
  });

  test('文件库重开保留迁移、完整路径与软删除账单引用', () async {
    final dir = Directory.systemTemp.createTempSync('category_move_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/ledger.sqlite');
    final first = AppDatabase(executor: NativeDatabase(file));
    late Map<String, Object?> expectedCategories;
    late Map<String, Object?> expectedBusiness;
    try {
      await seedMove(first);
      await first.upsertBill(
        id: 'bill',
        type: 0,
        amount: 1234,
        categoryId: 'moving',
        accountId: 'acc_cash',
        dateMs: 123,
        note: '重开保留',
      );
      await first.softDeleteBill('bill');
      await first.moveSubcategory(
        id: 'moving',
        expectedParentId: 'from',
        targetParentId: 'to',
      );
      expectedCategories = await categoryRows(first);
      expectedBusiness = await businessRows(first);
    } finally {
      await first.close();
    }
    final second = AppDatabase(executor: NativeDatabase(file));
    try {
      expect(await categoryRows(second), expectedCategories);
      expect(await businessRows(second), expectedBusiness);
      expect(
        CategoryHierarchy(await second.getAllCategories()).pathOf('moving'),
        '新一级 / 待迁移二级',
      );
      await second.restoreBill('bill');
      final restored = (await second.getAllBills()).single;
      expect(restored.categoryId, 'moving');
      expect(restored.amount, 1234);
      expect(restored.note, '重开保留');
    } finally {
      await second.close();
    }
  });
}
