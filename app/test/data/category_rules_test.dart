import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';

import '../helpers/test_support.dart';

Future<void> addCategory(
  AppDatabase db,
  String id,
  String name, {
  int kind = 0,
  String? parentId,
  int sort = 10,
}) => db.upsertCategory(
  id: id,
  name: name,
  emoji: '🍜',
  kind: kind,
  sort: sort,
  parentId: parentId,
);

Future<Map<String, Object?>> categoryRows(AppDatabase db) async => {
  for (final c in await db.getAllCategories()) c.id: c.toJson(),
};

void main() {
  late AppDatabase db;
  setUp(() async {
    db = TestAppDatabase();
    await db.getAllAccounts();
  });
  tearDown(() => db.close());

  test('带预期快照的分类编辑拒绝已删除或已改名记录，不重建或覆盖', () async {
    await addCategory(db, 'editing', '原分类');
    final original = (await db.getAllCategories()).singleWhere(
      (c) => c.id == 'editing',
    );
    await db.upsertCategory(
      id: original.id,
      name: '最新分类',
      emoji: '☕',
      kind: original.kind,
      sort: original.sort,
      expected: original,
    );
    final renamed = await categoryRows(db);
    await expectLater(
      db.upsertCategory(
        id: original.id,
        name: '旧窗口',
        emoji: '🍜',
        kind: original.kind,
        sort: original.sort,
        expected: original,
      ),
      throwsStateError,
    );
    expect(await categoryRows(db), renamed);
    await db.deleteCategory(original.id);
    final deleted = await categoryRows(db);
    await expectLater(
      db.upsertCategory(
        id: original.id,
        name: '不能重建',
        emoji: '🍜',
        kind: original.kind,
        sort: original.sort,
        expected: original,
      ),
      throwsStateError,
    );
    expect(await categoryRows(db), deleted);
  });

  for (final kind in [0, 1]) {
    test('类型 $kind 的父子分类改名换图标保留父级并规范名称', () async {
      await addCategory(db, 'parent', '父级', kind: kind);
      await addCategory(db, 'child', '  子级  ', kind: kind, parentId: 'parent');
      await db.upsertCategory(
        id: 'child',
        name: '  新子级  ',
        emoji: '☕',
        kind: kind,
        sort: 7,
      );
      final child = (await db.getAllCategories()).singleWhere(
        (c) => c.id == 'child',
      );
      expect(child.parentId, 'parent');
      expect(child.name, '新子级');
      expect(child.emoji, '☕');
      expect(child.sort, 7);
    });
  }

  test('非法父级、三级、自循环与内部类型二级均拒绝且不改库', () async {
    await addCategory(db, 'parent', '父级');
    await addCategory(db, 'child', '子级', parentId: 'parent');
    final before = await categoryRows(db);
    final attempts = [
      () => addCategory(db, 'missing', '不存在父级', parentId: 'ghost'),
      () => addCategory(db, 'cross', '跨类型', kind: 1, parentId: 'parent'),
      () => addCategory(db, 'third', '三级', parentId: 'child'),
      () => addCategory(db, 'self', '自循环', parentId: 'self'),
      () => addCategory(
        db,
        'internal',
        '内部二级',
        kind: 2,
        parentId: 'cat_aa_marker',
      ),
      () => addCategory(db, 'invalid-kind', '非法类型', kind: 9),
      () => addCategory(db, 'blank', '  '),
      () => addCategory(db, 'path-name', '餐饮 / 早餐'),
    ];
    for (final attempt in attempts) {
      await expectLater(attempt(), throwsStateError);
      expect(await categoryRows(db), before);
    }
  });

  test('已存在分类不能移动父级或更换类型，根节点不能挂到自己的子级', () async {
    await addCategory(db, 'parent', '父级');
    await addCategory(db, 'other', '另一个父级');
    await addCategory(db, 'child', '子级', parentId: 'parent');
    final before = await categoryRows(db);
    for (final attempt in [
      () => addCategory(db, 'child', '子级', parentId: 'other'),
      () => addCategory(db, 'child', '子级', kind: 1),
      () => addCategory(db, 'parent', '父级', parentId: 'child'),
    ]) {
      await expectLater(attempt(), throwsStateError);
      expect(await categoryRows(db), before);
    }
  });

  test('重名按类型和父级隔离，首尾空白不绕过重名校验', () async {
    await addCategory(db, 'parent-a', '甲');
    await addCategory(db, 'parent-b', '乙');
    await addCategory(db, 'a', '早餐', parentId: 'parent-a');
    await addCategory(db, 'a-other', '点心', parentId: 'parent-a');
    await addCategory(db, 'b', '早餐', parentId: 'parent-b');
    await addCategory(db, 'income', '早餐', kind: 1);
    await addCategory(db, 'root', '早餐');
    final before = await categoryRows(db);
    await expectLater(
      addCategory(db, 'duplicate', ' 早餐 ', parentId: 'parent-a'),
      throwsStateError,
    );
    await expectLater(addCategory(db, 'a-other', ' 早餐 '), throwsStateError);
    await expectLater(
      addCategory(db, 'root-duplicate', '早餐'),
      throwsStateError,
    );
    expect(await categoryRows(db), before);
    await addCategory(db, 'a', '早餐', parentId: 'parent-a');
  });

  test('删除有子分类的一级被阻止，删除未引用子级后才可删父级', () async {
    await addCategory(db, 'parent', '父级');
    await addCategory(db, 'child', '子级', parentId: 'parent');
    final before = await categoryRows(db);
    await expectLater(db.deleteCategory('parent'), throwsStateError);
    expect(await categoryRows(db), before);
    await db.deleteCategory('child');
    await db.deleteCategory('parent');
    final ids = (await db.getAllCategories()).map((c) => c.id);
    expect(ids, isNot(contains('child')));
    expect(ids, isNot(contains('parent')));
  });

  for (final deleted in [false, true]) {
    test('${deleted ? '软删除' : '正常'}账单仍保护分类引用', () async {
      await addCategory(db, 'referenced', '引用分类');
      await db.upsertBill(
        id: 'bill',
        type: 0,
        amount: 1234,
        categoryId: 'referenced',
        accountId: 'acc_cash',
        dateMs: 1,
      );
      if (deleted) await db.softDeleteBill('bill');
      final before = await categoryRows(db);
      final billBefore = (await db.select(db.bills).get()).single.toJson();
      expect(await db.billCountOfCategory('referenced'), 1);
      await expectLater(db.deleteCategory('referenced'), throwsStateError);
      expect(await categoryRows(db), before);
      expect((await db.select(db.bills).get()).single.toJson(), billBefore);
    });
  }

  test('排序只改同级完整列表，混级、跨类型、缺失、重复及不完整请求原子拒绝', () async {
    await addCategory(db, 'parent-a', '甲');
    await addCategory(db, 'parent-b', '乙');
    await addCategory(db, 'a1', '甲一', parentId: 'parent-a', sort: 5);
    await addCategory(db, 'a2', '甲二', parentId: 'parent-a', sort: 8);
    await addCategory(db, 'b1', '乙一', parentId: 'parent-b', sort: 9);
    await addCategory(db, 'i1', '收入测试', kind: 1);
    final before = await categoryRows(db);
    for (final ids in [
      ['a1', 'b1'],
      ['a1', 'parent-a'],
      ['a1', 'i1'],
      ['a1', 'ghost'],
      ['a1', 'a1'],
      ['a1'],
    ]) {
      await expectLater(db.reorderCategories(ids), throwsStateError);
      expect(await categoryRows(db), before);
    }
    await db.reorderCategories(['a2', 'a1']);
    final after = await categoryRows(db);
    expect((after['a2'] as Map)['sort'], 0);
    expect((after['a1'] as Map)['sort'], 1);
    for (final id in before.keys.where((id) => id != 'a1' && id != 'a2')) {
      expect(after[id], before[id]);
    }
    await db.reorderCategories([]);
    expect(await categoryRows(db), after);
  });

  test('异常旧分类不静默修复，拒绝在孤儿或循环分类下新增', () async {
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: 'orphan',
            name: '孤儿',
            emoji: '🍜',
            kind: 0,
            parentId: const Value('ghost'),
          ),
        );
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: 'cycle',
            name: '循环',
            emoji: '🍜',
            kind: 0,
            parentId: const Value('cycle'),
          ),
        );
    final before = await categoryRows(db);
    await expectLater(
      addCategory(db, 'new', '新子级', parentId: 'orphan'),
      throwsStateError,
    );
    await expectLater(
      addCategory(db, 'new', '新子级', parentId: 'cycle'),
      throwsStateError,
    );
    expect(await categoryRows(db), before);
  });

  test('文件库重开保留父子、排序和原始账单引用', () async {
    final dir = Directory.systemTemp.createTempSync('category_rules_');
    final path = File('${dir.path}/ledger.sqlite');
    final first = AppDatabase(executor: NativeDatabase(path));
    addTearDown(() => dir.deleteSync(recursive: true));
    try {
      await addCategory(first, 'parent', '父级');
      await addCategory(first, 'a', '子甲', parentId: 'parent');
      await addCategory(first, 'b', '子乙', parentId: 'parent');
      await first.reorderCategories(['b', 'a']);
      await first.upsertBill(
        id: 'bill',
        type: 0,
        amount: 1234,
        accountId: 'acc_cash',
        categoryId: 'a',
        dateMs: 1,
      );
    } finally {
      await first.close();
    }
    final second = AppDatabase(executor: NativeDatabase(path));
    try {
      final rows = await second.getAllCategories();
      expect(rows.singleWhere((c) => c.id == 'a').parentId, 'parent');
      expect(rows.singleWhere((c) => c.id == 'b').sort, 0);
      final bill = (await second.getAllBills()).single;
      expect(bill.categoryId, 'a');
      expect(bill.amount, 1234);
      await expectLater(second.deleteCategory('a'), throwsStateError);
    } finally {
      await second.close();
    }
  });
}
