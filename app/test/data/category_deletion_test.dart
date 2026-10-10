import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/category_hierarchy.dart';
import 'package:aa_expense_splitter/utils/balance.dart';

import '../helpers/test_support.dart';

Future<void> addDeleteCategory(
  AppDatabase db,
  String id,
  String name, {
  int kind = 0,
  String? parent,
  int sort = 0,
}) => db.upsertCategory(
  id: id,
  name: name,
  emoji: '🍜',
  kind: kind,
  parentId: parent,
  sort: sort,
);

Future<void> addDeleteBill(
  AppDatabase db,
  String id,
  String categoryId, {
  int type = 0,
  int amount = 1234,
  String? groupId,
  String? settlementId,
}) => db.upsertBill(
  id: id,
  type: type,
  amount: amount,
  categoryId: categoryId,
  accountId: 'acc_wechat',
  toAccountId: type == 2 ? 'acc_cash' : null,
  dateMs: 1234567890000,
  note: '保留备注 $id',
  createdAt: 77,
  aaGroupId: groupId,
  settlementId: settlementId,
);

Future<void> seedDeletion(AppDatabase db, {int kind = 0}) async {
  await db.getAllAccounts();
  await addDeleteCategory(db, 'source', '待删除一级', kind: kind, sort: -10);
  await addDeleteCategory(
    db,
    'source-child',
    '待删除二级甲',
    kind: kind,
    parent: 'source',
    sort: 2,
  );
  await addDeleteCategory(
    db,
    'source-child-2',
    '待删除二级乙',
    kind: kind,
    parent: 'source',
    sort: 7,
  );
  await addDeleteCategory(db, 'target', '已有一级', kind: kind, sort: -9);
  await addDeleteCategory(
    db,
    'target-child',
    '已有二级',
    kind: kind,
    parent: 'target',
    sort: 11,
  );
  await addDeleteCategory(db, 'keeper', '旁观一级', kind: kind, sort: -8);
  await addDeleteBill(db, 'direct', 'source', type: kind, amount: 101);
  await addDeleteBill(db, 'child', 'source-child', type: kind, amount: 202);
  await addDeleteBill(db, 'deleted', 'source-child-2', type: kind, amount: 303);
  await db.softDeleteBill('deleted');
  await addDeleteBill(db, 'outside', 'target', type: kind, amount: 404);
}

Future<void> withDeletion(
  Future<void> Function(AppDatabase db) action, {
  int kind = 0,
}) async {
  final db = TestAppDatabase();
  try {
    await seedDeletion(db, kind: kind);
    await action(db);
  } finally {
    await db.close();
  }
}

Future<Category> deleteCategoryRow(AppDatabase db, String id) async =>
    (await db.getAllCategories()).singleWhere((category) => category.id == id);

Future<Map<String, Object?>> deleteSnapshot(AppDatabase db) async => {
  'categories': {
    for (final row in await db.getAllCategories()) row.id: row.toJson(),
  },
  'bills': {
    for (final row in await db.select(db.bills).get()) row.id: row.toJson(),
  },
  'accounts': {
    for (final row in await db.getAllAccounts()) row.id: row.toJson(),
  },
  'groups': {for (final row in await db.getAllAaGroups()) row.id: row.toJson()},
  'settlements': {
    for (final row in await db.select(db.settlements).get())
      row.id: row.toJson(),
  },
  'meta': {
    for (final row in await db.select(db.metaEntries).get())
      row.key: row.toJson(),
  },
};

Future<void> expectReclassifiedOnly(
  AppDatabase db,
  Map<String, Bill> before,
  Set<String> changedIds,
  String? destinationId,
) async {
  final after = {
    for (final bill in await db.select(db.bills).get()) bill.id: bill,
  };
  expect(after.keys.toSet(), before.keys.toSet());
  for (final id in before.keys) {
    expect(after[id]!.toJson(), {
      ...before[id]!.toJson(),
      if (changedIds.contains(id)) 'categoryId': destinationId,
    }, reason: '账单 $id 除分类外的字段须完整保留');
  }
}

Future<void> addDeleteGroup(
  AppDatabase db, {
  bool settled = false,
  String? settlementId,
}) => db.upsertAaGroup(
  AaGroupsCompanion.insert(
    id: 'group',
    ownerUid: 'owner',
    payerUid: 'partner',
    totalAmount: 2468,
    dateMs: 1234567890000,
    note: const Value('历史同步备注'),
    categoryName: const Value('待删除一级 / 待删除二级甲'),
    categoryEmoji: const Value('🍜'),
    status: const Value(1),
    statusByUid: const Value('partner'),
    statusAtMs: const Value(123),
    statusNote: const Value('确认备注'),
    settled: Value(settled),
    settlementId: Value(settlementId),
    createdAtMs: 78,
    updatedAtMs: 79,
  ),
);

void main() {
  test('删除预览包含完整分组和软删除引用，列表不可变且取消无写入', () async {
    await withDeletion((db) async {
      final before = await deleteSnapshot(db);
      final preview = await db.previewCategoryDeletion('source');
      expect(preview.sourceId, 'source');
      expect(preview.categories.map((category) => category.id).toSet(), {
        'source',
        'source-child',
        'source-child-2',
      });
      expect(preview.bills.map((bill) => bill.id).toSet(), {
        'direct',
        'child',
        'deleted',
      });
      expect(preview.activeBillCount, 2);
      expect(preview.deletedBillCount, 1);
      expect(() => preview.categories.clear(), throwsUnsupportedError);
      expect(() => preview.bills.clear(), throwsUnsupportedError);
      expect(await deleteSnapshot(db), before);
      final leaf = await db.previewCategoryDeletion('source-child');
      expect(leaf.categories.map((category) => category.id), ['source-child']);
      expect(leaf.bills.map((bill) => bill.id), ['child']);
      await expectLater(
        db.previewCategoryDeletion('missing'),
        throwsStateError,
      );
      expect(await deleteSnapshot(db), before);
    });
  });

  for (final kind in [0, 1]) {
    for (final mode in [
      'existing',
      'create-root',
      'create-child',
      'uncategorized',
    ]) {
      test('类型 $kind 整组删除转到 $mode，所有引用只改分类且余额不变', () async {
        await withDeletion((db) async {
          final preview = await db.previewCategoryDeletion('source');
          final before = await deleteSnapshot(db);
          final beforeBills = {
            for (final bill in await db.select(db.bills).get()) bill.id: bill,
          };
          final beforeBalances = computeBalances(
            await db.getAllAccounts(),
            await db.getAllBills(),
          );
          final target = await deleteCategoryRow(db, 'target');
          final targetChild = await deleteCategoryRow(db, 'target-child');
          final destination = switch (mode) {
            'existing' => CategoryDeleteDestination.existing(
              targetChild,
              parent: target,
            ),
            'create-root' => CategoryDeleteDestination.create(
              id: 'new-target',
              name: '  新一级  ',
              emoji: '☕',
            ),
            'create-child' => CategoryDeleteDestination.create(
              id: 'new-target',
              name: '  新二级  ',
              emoji: '☕',
              parent: target,
            ),
            _ => const CategoryDeleteDestination.uncategorized(),
          };
          final destinationId = mode == 'existing'
              ? 'target-child'
              : mode == 'uncategorized'
              ? null
              : 'new-target';
          await db.deleteCategoryAndReassign(
            expected: preview,
            destination: destination,
            confirmWholeGroup: true,
          );
          await expectReclassifiedOnly(db, beforeBills, {
            'direct',
            'child',
            'deleted',
          }, destinationId);
          final after = await deleteSnapshot(db);
          for (final table in ['accounts', 'groups', 'settlements', 'meta']) {
            expect(after[table], before[table]);
          }
          final beforeCategories =
              before['categories']! as Map<String, dynamic>;
          final afterCategories = after['categories']! as Map<String, dynamic>;
          for (final id in ['source', 'source-child', 'source-child-2']) {
            expect(afterCategories.containsKey(id), isFalse);
          }
          for (final id in beforeCategories.keys.where(
            (id) => !id.startsWith('source'),
          )) {
            expect(afterCategories[id], beforeCategories[id]);
          }
          if (mode.startsWith('create')) {
            final created = await deleteCategoryRow(db, 'new-target');
            expect(created.kind, kind);
            expect(created.name, mode == 'create-root' ? '新一级' : '新二级');
            expect(created.emoji, '☕');
            expect(created.parentId, mode == 'create-root' ? null : 'target');
            expect(created.isPreset, isFalse);
            if (mode == 'create-child') expect(created.sort, 12);
          }
          expect(
            computeBalances(await db.getAllAccounts(), await db.getAllBills()),
            beforeBalances,
          );
          expect(await db.billCountOfCategory('source'), 0);
          expect(await db.billCountOfCategory('source-child'), 0);
          expect(await db.billCountOfCategory('source-child-2'), 0);
        }, kind: kind);
      });
    }
  }

  test('有子级的整组删除必须显式确认，拒绝时连新分类也不创建', () async {
    await withDeletion((db) async {
      final preview = await db.previewCategoryDeletion('source');
      final before = await deleteSnapshot(db);
      await expectLater(
        db.deleteCategoryAndReassign(
          expected: preview,
          destination: CategoryDeleteDestination.create(
            id: 'new',
            name: '新分类',
            emoji: '☕',
          ),
        ),
        throwsStateError,
      );
      expect(await deleteSnapshot(db), before);
    });
  });

  test('单个二级删除不删除父级兄弟，软删除引用迁移后可安全恢复', () async {
    await withDeletion((db) async {
      final preview = await db.previewCategoryDeletion('source-child-2');
      final before = await deleteSnapshot(db);
      final bills = {
        for (final bill in await db.select(db.bills).get()) bill.id: bill,
      };
      expect(preview.activeBillCount, 0);
      expect(preview.deletedBillCount, 1);
      await db.deleteCategoryAndReassign(
        expected: preview,
        destination: CategoryDeleteDestination.existing(
          await deleteCategoryRow(db, 'target'),
        ),
      );
      await expectReclassifiedOnly(db, bills, {'deleted'}, 'target');
      final after = await deleteSnapshot(db);
      final categories = after['categories']! as Map<String, dynamic>;
      final originalCategories = before['categories']! as Map<String, dynamic>;
      expect(categories, {...originalCategories}..remove('source-child-2'));
      await db.restoreBill('deleted');
      final restored = (await db.getAllBills()).singleWhere(
        (bill) => bill.id == 'deleted',
      );
      expect(restored.categoryId, 'target');
      expect(restored.amount, bills['deleted']!.amount);
      expect(restored.note, bills['deleted']!.note);
      expect(restored.deletedAt, isNull);
      expect(
        CategoryHierarchy(await db.getAllCategories())
            .pathOf(restored.categoryId),
        '已有一级',
      );
    });
  });

  test('无账单的独立一级和二级可以直接删除且不影响任何业务记录', () async {
    await withDeletion((db) async {
      await addDeleteCategory(db, 'empty-root', '无账单一级');
      await addDeleteCategory(db, 'empty-child', '无账单二级', parent: 'keeper');
      for (final id in ['empty-root', 'empty-child']) {
        final preview = await db.previewCategoryDeletion(id);
        expect(preview.bills, isEmpty);
        expect(preview.activeBillCount, 0);
        expect(preview.deletedBillCount, 0);
        final before = await deleteSnapshot(db);
        await db.deleteCategoryAndReassign(
          expected: preview,
          destination: const CategoryDeleteDestination.uncategorized(),
        );
        final after = await deleteSnapshot(db);
        expect(after, {
          ...before,
          'categories': {...before['categories']! as Map<String, dynamic>}
            ..remove(id),
        });
      }
    });
  });

  test('零账单整组仍须明确确认，确认后零引用更新可成功并保留全部业务记录', () async {
    await withDeletion((db) async {
      await addDeleteCategory(db, 'empty-group', '空分组一级');
      await addDeleteCategory(
        db,
        'empty-group-child',
        '空分组二级',
        parent: 'empty-group',
      );
      final preview = await db.previewCategoryDeletion('empty-group');
      expect(preview.categories, hasLength(2));
      expect(preview.bills, isEmpty);
      expect(preview.activeBillCount, 0);
      expect(preview.deletedBillCount, 0);
      final before = await deleteSnapshot(db);
      await expectLater(
        db.deleteCategoryAndReassign(
          expected: preview,
          destination: const CategoryDeleteDestination.uncategorized(),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '请明确确认删除一级及其全部二级分类',
          ),
        ),
      );
      expect(await deleteSnapshot(db), before);
      await db.deleteCategoryAndReassign(
        expected: preview,
        destination: const CategoryDeleteDestination.uncategorized(),
        confirmWholeGroup: true,
      );
      expect(await deleteSnapshot(db), {
        ...before,
        'categories': {...before['categories']! as Map<String, dynamic>}
          ..remove('empty-group')
          ..remove('empty-group-child'),
      });
    });
  });

  test('来源改名、引用同数量替换及范围变动均拒绝陈旧确认，不影响并发新状态', () async {
    final mutations = <String, Future<void> Function(AppDatabase)>{
      'source renamed': (db) =>
          addDeleteCategory(db, 'source', '来源新名称', sort: -10),
      'child renamed': (db) => addDeleteCategory(
        db,
        'source-child',
        '二级新名称',
        parent: 'source',
        sort: 2,
      ),
      'new child': (db) =>
          addDeleteCategory(db, 'new-child', '新加入二级', parent: 'source'),
      'child moved out': (db) => db.moveSubcategory(
        id: 'source-child',
        expectedParentId: 'source',
        targetParentId: 'keeper',
      ),
      'same count bill replacement': (db) async {
        await (db.delete(
          db.bills,
        )..where((row) => row.id.equals('direct'))).go();
        await addDeleteBill(db, 'replacement', 'source', amount: 101);
      },
      'bill changed': (db) async {
        await (db.update(db.bills)..where((row) => row.id.equals('child')))
            .write(const BillsCompanion(note: Value('另一入口修改')));
      },
      'new reference': (db) =>
          addDeleteBill(db, 'new-reference', 'source-child'),
      'reference soft deleted': (db) => db.softDeleteBill('child'),
    };
    for (final mutation in mutations.entries) {
      await withDeletion((db) async {
        final preview = await db.previewCategoryDeletion('source');
        await mutation.value(db);
        final afterConcurrentChange = await deleteSnapshot(db);
        await expectLater(
          db.deleteCategoryAndReassign(
            expected: preview,
            destination: const CategoryDeleteDestination.uncategorized(),
            confirmWholeGroup: true,
          ),
          throwsStateError,
          reason: mutation.key,
        );
        expect(
          await deleteSnapshot(db),
          afterConcurrentChange,
          reason: mutation.key,
        );
      });
    }
    await withDeletion((db) async {
      final childPreview = await db.previewCategoryDeletion('source-child');
      await addDeleteCategory(db, 'source', '父级新名称', sort: -10);
      final changed = await deleteSnapshot(db);
      await expectLater(
        db.deleteCategoryAndReassign(
          expected: childPreview,
          destination: const CategoryDeleteDestination.uncategorized(),
        ),
        throwsStateError,
      );
      expect(await deleteSnapshot(db), changed);
    });
  });

  test('目标或目标父级快照变化、迁移或删除均拒绝，不偷偷选择替代分类', () async {
    for (final change in [
      'target rename',
      'parent rename',
      'target moved',
      'target deleted',
      'create parent rename',
    ]) {
      await withDeletion((db) async {
        final preview = await db.previewCategoryDeletion('source');
        final parent = await deleteCategoryRow(db, 'target');
        final child = await deleteCategoryRow(db, 'target-child');
        final destination = change == 'create parent rename'
            ? CategoryDeleteDestination.create(
                id: 'new',
                name: '新分类',
                emoji: '☕',
                parent: parent,
              )
            : CategoryDeleteDestination.existing(child, parent: parent);
        switch (change) {
          case 'target rename':
            await addDeleteCategory(
              db,
              'target-child',
              '目标新名称',
              parent: 'target',
              sort: 11,
            );
            break;
          case 'parent rename':
          case 'create parent rename':
            await addDeleteCategory(db, 'target', '目标父新名称', sort: -9);
            break;
          case 'target moved':
            await db.moveSubcategory(
              id: 'target-child',
              expectedParentId: 'target',
              targetParentId: 'keeper',
            );
            break;
          case 'target deleted':
            await db.deleteCategory('target-child');
            break;
        }
        final changed = await deleteSnapshot(db);
        await expectLater(
          db.deleteCategoryAndReassign(
            expected: preview,
            destination: destination,
            confirmWholeGroup: true,
          ),
          throwsStateError,
          reason: change,
        );
        expect(await deleteSnapshot(db), changed, reason: change);
      });
    }
  });

  test('重名、ID冲突、跨类型、删除范围内或无效目标原子拒绝', () async {
    await withDeletion((db) async {
      await addDeleteCategory(db, 'income', '收入分类', kind: 1);
      await addDeleteCategory(
        db,
        'target-child',
        '已有二级',
        parent: 'target',
        sort: 0x7FFFFFFFFFFFFFFF,
      );
      final preview = await db.previewCategoryDeletion('source');
      final source = await deleteCategoryRow(db, 'source');
      final target = await deleteCategoryRow(db, 'target');
      final targetChild = await deleteCategoryRow(db, 'target-child');
      final before = await deleteSnapshot(db);
      final destinations = [
        CategoryDeleteDestination.existing(source),
        CategoryDeleteDestination.existing(
          await deleteCategoryRow(db, 'source-child'),
          parent: source,
        ),
        CategoryDeleteDestination.existing(
          await deleteCategoryRow(db, 'income'),
        ),
        CategoryDeleteDestination.existing(target.copyWith(id: 'missing')),
        CategoryDeleteDestination.existing(targetChild),
        CategoryDeleteDestination.existing(targetChild, parent: source),
        CategoryDeleteDestination.create(
          id: 'source',
          name: '复用待删ID',
          emoji: '☕',
        ),
        CategoryDeleteDestination.create(
          id: 'target',
          name: '其他名称',
          emoji: '☕',
        ),
        CategoryDeleteDestination.create(id: '', name: '空ID', emoji: '☕'),
        CategoryDeleteDestination.create(
          id: 'duplicate',
          name: '  已有二级  ',
          emoji: '☕',
          parent: target,
        ),
        CategoryDeleteDestination.create(id: 'blank', name: '   ', emoji: '☕'),
        CategoryDeleteDestination.create(
          id: 'separator',
          name: '路径 / 名称',
          emoji: '☕',
        ),
        CategoryDeleteDestination.create(
          id: 'third',
          name: '三级目标',
          emoji: '☕',
          parent: targetChild,
        ),
        CategoryDeleteDestination.create(
          id: 'inside',
          name: '范围内目标',
          emoji: '☕',
          parent: source,
        ),
        CategoryDeleteDestination.create(
          id: 'missing-parent',
          name: '缺父目标',
          emoji: '☕',
          parent: target.copyWith(id: 'missing'),
        ),
        CategoryDeleteDestination.create(
          id: 'max-sort',
          name: '排序溢出目标',
          emoji: '☕',
          parent: target,
        ),
      ];
      for (final destination in destinations) {
        await expectLater(
          db.deleteCategoryAndReassign(
            expected: preview,
            destination: destination,
            confirmWholeGroup: true,
          ),
          throwsStateError,
        );
        expect(await deleteSnapshot(db), before);
      }
    });
  });

  test('内部类型、孤儿、跨类型归属、循环及原始三级引用不允许删除转移', () async {
    for (final shape in [
      'internal',
      'orphan',
      'cross',
      'self',
      'cycle',
      'third',
      'raw-cross-child',
      'cross-kind-direct',
    ]) {
      await withDeletion((db) async {
        await addDeleteCategory(db, 'income', '收入父级', kind: 1);
        var sourceId = 'bad';
        final parent = switch (shape) {
          'orphan' => 'missing',
          'cross' => 'income',
          'self' => 'bad',
          'cycle' => 'cycle-peer',
          'third' => 'source-child',
          'raw-cross-child' => 'source-child',
          'cross-kind-direct' => 'source',
          _ => null,
        };
        await db
            .into(db.categories)
            .insert(
              CategoriesCompanion.insert(
                id: 'bad',
                name: '异常分类',
                emoji: '📦',
                kind: shape == 'internal' || shape == 'raw-cross-child'
                    ? 2
                    : shape == 'cross-kind-direct'
                    ? 1
                    : 0,
                parentId: Value(parent),
              ),
            );
        if (shape == 'cycle') {
          await db
              .into(db.categories)
              .insert(
                CategoriesCompanion.insert(
                  id: 'cycle-peer',
                  name: '循环另一端',
                  emoji: '📦',
                  kind: 0,
                  parentId: const Value('bad'),
                ),
              );
        }
        if (shape == 'third' ||
            shape == 'raw-cross-child' ||
            shape == 'cross-kind-direct') {
          sourceId = 'source';
        }
        final before = await deleteSnapshot(db);
        Future<void> attempt() async {
          final preview = await db.previewCategoryDeletion(sourceId);
          await db.deleteCategoryAndReassign(
            expected: preview,
            destination: const CategoryDeleteDestination.uncategorized(),
            confirmWholeGroup: true,
          );
        }

        await expectLater(attempt(), throwsStateError, reason: shape);
        expect(await deleteSnapshot(db), before, reason: shape);
      });
    }
  });

  test('任一受保护或混乱AA引用让整个分组拒绝，软删和普通同行都不改动', () async {
    for (final shape in [
      'settlement',
      'deleted settlement',
      'settled group',
      'group settlement',
      'legacy income',
      'missing group',
      'isolated flag',
      'missing flag',
      'mixed links',
    ]) {
      await withDeletion((db) async {
        final linked = ![
          'settlement',
          'deleted settlement',
          'isolated flag',
        ].contains(shape);
        if (linked && shape != 'missing group') {
          await addDeleteGroup(
            db,
            settled: shape == 'settled group',
            settlementId: shape == 'group settlement' ? 'settlement' : null,
          );
        }
        await addDeleteBill(
          db,
          'protected',
          'source-child',
          type: shape == 'legacy income' ? 1 : 0,
          groupId: linked
              ? (shape == 'missing group' ? 'missing-group' : 'group')
              : null,
          settlementId:
              [
                'settlement',
                'deleted settlement',
                'mixed links',
              ].contains(shape)
              ? 'settlement'
              : null,
        );
        if (shape == 'deleted settlement') await db.softDeleteBill('protected');
        if (shape == 'isolated flag' || shape == 'missing flag') {
          await (db.update(db.bills)
                ..where((bill) => bill.id.equals('protected')))
              .write(BillsCompanion(isAa: Value(shape == 'isolated flag')));
        }
        final preview = await db.previewCategoryDeletion('source');
        final before = await deleteSnapshot(db);
        await expectLater(
          db.deleteCategoryAndReassign(
            expected: preview,
            destination: CategoryDeleteDestination.create(
              id: 'must-not-exist',
              name: '新目标',
              emoji: '☕',
            ),
            confirmWholeGroup: true,
          ),
          throwsStateError,
          reason: shape,
        );
        expect(await deleteSnapshot(db), before, reason: shape);
      });
    }
  });

  test('未结算正常AA支出只改本机分类，不重写组快照、账单关联或余额', () async {
    await withDeletion((db) async {
      await addDeleteGroup(db);
      await addDeleteBill(db, 'aa', 'source-child', groupId: 'group');
      final preview = await db.previewCategoryDeletion('source');
      final before = await deleteSnapshot(db);
      final bills = {
        for (final bill in await db.select(db.bills).get()) bill.id: bill,
      };
      final balances = computeBalances(
        await db.getAllAccounts(),
        await db.getAllBills(),
      );
      await db.deleteCategoryAndReassign(
        expected: preview,
        destination: CategoryDeleteDestination.existing(
          await deleteCategoryRow(db, 'target'),
        ),
        confirmWholeGroup: true,
      );
      await expectReclassifiedOnly(db, bills, {
        'direct',
        'child',
        'deleted',
        'aa',
      }, 'target');
      final after = await deleteSnapshot(db);
      for (final table in ['accounts', 'groups', 'settlements', 'meta']) {
        expect(after[table], before[table]);
      }
      expect(
        computeBalances(await db.getAllAccounts(), await db.getAllBills()),
        balances,
      );
    });
  });

  test('预览后AA组结算即使账单快照未变仍在提交时整组拒绝', () async {
    await withDeletion((db) async {
      await addDeleteGroup(db);
      await addDeleteBill(db, 'aa', 'source-child', groupId: 'group');
      final preview = await db.previewCategoryDeletion('source');
      await db.markGroupsSettled(['group'], 'settlement', 300);
      final changed = await deleteSnapshot(db);
      await expectLater(
        db.deleteCategoryAndReassign(
          expected: preview,
          destination: const CategoryDeleteDestination.uncategorized(),
          confirmWholeGroup: true,
        ),
        throwsStateError,
      );
      expect(await deleteSnapshot(db), changed);
    });
  });

  test('删除后旧页面upsert不能写回缺失分类，同时保留跨类型旧数据兼容', () async {
    await withDeletion((db) async {
      final preview = await db.previewCategoryDeletion('source-child');
      await db.deleteCategoryAndReassign(
        expected: preview,
        destination: const CategoryDeleteDestination.uncategorized(),
      );
      final before = await deleteSnapshot(db);
      for (final id in ['child', 'new-bill']) {
        await expectLater(
          addDeleteBill(db, id, 'source-child', amount: 999),
          throwsStateError,
        );
        expect(await deleteSnapshot(db), before);
      }
      await addDeleteBill(db, 'legacy-type', 'target', type: 1);
      expect(
        (await db.getAllBills())
            .singleWhere((bill) => bill.id == 'legacy-type')
            .categoryId,
        'target',
      );
      await db.upsertBill(
        id: 'uncategorized-new',
        type: 0,
        amount: 100,
        accountId: 'acc_cash',
        dateMs: 123,
      );
      expect(
        (await db.getAllBills())
            .singleWhere((bill) => bill.id == 'uncategorized-new')
            .categoryId,
        isNull,
      );
    });
  });

  test('最后删除被SQLite触发器拒绝时，新分类、全部引用及分组删除一起回滚', () async {
    await withDeletion((db) async {
      final preview = await db.previewCategoryDeletion('source');
      final before = await deleteSnapshot(db);
      await db.customStatement(
        "CREATE TRIGGER fail_final_category_delete BEFORE DELETE ON categories WHEN OLD.id = 'source' BEGIN SELECT RAISE(ABORT, 'test-final-delete-abort'); END",
      );
      await expectLater(
        db.deleteCategoryAndReassign(
          expected: preview,
          destination: CategoryDeleteDestination.create(
            id: 'rollback-new',
            name: '回滚新分类',
            emoji: '☕',
          ),
          confirmWholeGroup: true,
        ),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('test-final-delete-abort'),
          ),
        ),
      );
      expect(await deleteSnapshot(db), before);
      await db.customStatement('DROP TRIGGER fail_final_category_delete');
    });
  });

  test('同库并发删除相同快照只能成功一次，失败请求不能覆盖赢家分类', () async {
    await withDeletion((db) async {
      final preview = await db.previewCategoryDeletion('source');
      final bills = {
        for (final bill in await db.select(db.bills).get()) bill.id: bill,
      };
      final target = await deleteCategoryRow(db, 'target');
      final keeper = await deleteCategoryRow(db, 'keeper');
      Future<Object> attempt(Category category) => db
          .deleteCategoryAndReassign(
            expected: preview,
            destination: CategoryDeleteDestination.existing(category),
            confirmWholeGroup: true,
          )
          .then<Object>((_) => category.id, onError: (Object error) => error);
      final results = await Future.wait([attempt(target), attempt(keeper)]);
      final winner = results.whereType<String>().single;
      expect(results.whereType<StateError>(), hasLength(1));
      await expectReclassifiedOnly(db, bills, {
        'direct',
        'child',
        'deleted',
      }, winner);
      expect(
        (await db.getAllCategories()).where(
          (category) => category.id.startsWith('source'),
        ),
        isEmpty,
      );
    });
  });

  test('文件库重开保留删除转移，新分类路径及软删除账单恢复后引用完整', () async {
    final directory = Directory.systemTemp.createTempSync('category_delete_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/ledger.sqlite');
    final first = AppDatabase(executor: NativeDatabase(file));
    late Map<String, Object?> expected;
    try {
      await seedDeletion(first, kind: 1);
      final preview = await first.previewCategoryDeletion('source');
      await first.deleteCategoryAndReassign(
        expected: preview,
        destination: CategoryDeleteDestination.create(
          id: 'new',
          name: '新二级收入',
          emoji: '💰',
          parent: await deleteCategoryRow(first, 'target'),
        ),
        confirmWholeGroup: true,
      );
      expected = await deleteSnapshot(first);
    } finally {
      await first.close();
    }
    final second = AppDatabase(executor: NativeDatabase(file));
    try {
      expect(await deleteSnapshot(second), expected);
      expect(
        CategoryHierarchy(await second.getAllCategories()).pathOf('new'),
        '已有一级 / 新二级收入',
      );
      await second.restoreBill('deleted');
      final restored = (await second.getAllBills()).singleWhere(
        (bill) => bill.id == 'deleted',
      );
      expect(restored.categoryId, 'new');
      expect(restored.type, 1);
      expect(restored.amount, 303);
      expect(restored.note, '保留备注 deleted');
    } finally {
      await second.close();
    }
  });
}
