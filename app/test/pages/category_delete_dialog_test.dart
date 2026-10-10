import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/categories_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/widgets/category_delete_dialog.dart';

import '../helpers/test_support.dart';

Finder deleteKey(String key) => find.byKey(ValueKey(key));
Finder confirmation() => find.widgetWithText(FilledButton, '确认转移并删除');

Future<void> seedDeleteUi(AppDatabase db, {int kind = 0}) async {
  await db.getAllAccounts();
  await db.delete(db.categories).go();
  for (final row in [
    (id: 'source', name: '待删一级', parent: null),
    (id: 'child', name: '待删二级', parent: 'source'),
    (id: 'target', name: '目标一级', parent: null),
    (id: 'target-child', name: '目标二级', parent: 'target'),
  ]) {
    await db.upsertCategory(
      id: row.id,
      name: row.name,
      emoji: '☕',
      kind: kind,
      sort: 0,
      parentId: row.parent,
    );
  }
  for (final row in [
    (id: 'active', category: 'child', amount: 1234),
    (id: 'trash', category: 'source', amount: 5678),
  ]) {
    await db.upsertBill(
      id: row.id,
      type: kind,
      amount: row.amount,
      categoryId: row.category,
      accountId: 'acc_wechat',
      dateMs: DateTime.now().millisecondsSinceEpoch,
      note: '保留${row.id}',
      createdAt: 77,
    );
  }
  await db.softDeleteBill('trash');
}

Future<void> click(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await settleProviders(tester);
}

Future<void> commitClick(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await settleProviders(tester);
}

Future<void> openDeletion(
  WidgetTester tester, {
  int kind = 0,
  String id = 'source',
}) async {
  if (kind == 1) await click(tester, find.text('收入'));
  await click(tester, deleteKey('category-row-$id'));
  await commitClick(tester, find.widgetWithText(TextButton, '删除'));
  expect(find.byType(CategoryDeleteDialog), findsOneWidget);
}

Future<void> dropdown(WidgetTester tester, String key, String label) async {
  await click(tester, deleteKey(key));
  await click(tester, find.text(label).last);
}

Future<void> finishGate(WidgetTester tester, GatedDeleteUiDb db) async {
  for (var i = 0; i < 40 && !db.finished.isCompleted; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(db.finished.isCompleted, isTrue);
  await settleProviders(tester);
}

class GatedDeleteUiDb extends TestAppDatabase {
  final entered = Completer<void>();
  final finished = Completer<void>();
  final release = Completer<void>();
  int calls = 0;

  @override
  Future<void> deleteCategoryAndReassign({
    required CategoryDeletePreview expected,
    required CategoryDeleteDestination destination,
    bool confirmWholeGroup = false,
  }) async {
    calls++;
    entered.complete();
    try {
      await release.future;
      await super.deleteCategoryAndReassign(
        expected: expected,
        destination: destination,
        confirmWholeGroup: confirmWholeGroup,
      );
    } finally {
      finished.complete();
    }
  }
}

class GatedPreviewUiDb extends GatedDeleteUiDb {
  @override
  Future<CategoryDeletePreview> previewCategoryDeletion(String id) async {
    entered.complete();
    try {
      await release.future;
      return await super.previewCategoryDeletion(id);
    } finally {
      finished.complete();
    }
  }
}

void main() {
  testWidgets('读取删除范围期间返回，不弹出迟到窗口或退出底层页面', (tester) async {
    late GatedPreviewUiDb db;
    await tester.runAsync(() async {
      db = GatedPreviewUiDb();
    });
    await seedDeleteUi(db);
    final categories = await db.getAllCategories();
    final bills = await db.select(db.bills).get();
    await pumpPage(tester, const CategoriesPage(), db: db);
    await click(tester, deleteKey('category-row-source'));
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await db.entered.future.timeout(const Duration(seconds: 3));
    });
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    db.release.complete();
    await finishGate(tester, db);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('分类管理'), findsOneWidget);
    expect(await db.getAllCategories(), categories);
    expect(await db.select(db.bills).get(), bills);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('已有去向只含同类型且不在删除范围内的一级及二级', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    await db.upsertCategory(
      id: 'income',
      name: '其他收入',
      emoji: '💰',
      kind: 1,
      sort: 0,
    );
    await db.upsertCategory(
      id: 'internal',
      name: '内部往来',
      emoji: '💰',
      kind: 2,
      sort: 0,
    );
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '已有分类'));
    final field = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: deleteKey('category-delete-target'),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    expect(field.items!.map((item) => item.value).toList(), [
      'target',
      'target-child',
    ]);
    final targetPreview = await db.previewCategoryDeletion('target');
    await db.deleteCategoryAndReassign(
      expected: targetPreview,
      destination: const CategoryDeleteDestination.uncategorized(),
      confirmWholeGroup: true,
    );
    await settleProviders(tester);
    expect(find.text('暂无可用分类，可新增分类或转到未分类。'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirmation()).onPressed, isNull);
    await click(tester, find.widgetWithText(ChoiceChip, '未分类'));
    await click(tester, deleteKey('category-delete-whole-group'));
    await commitClick(tester, confirmation());
    expect((await db.getAllCategories()).map((c) => c.id).toSet(), {
      'income',
      'internal',
    });
    expect((await db.getAllBills()).single.categoryId, isNull);
    await disposePage(tester, db);
  });

  testWidgets('点击提交之后目标消失，事务失败保留窗口和所有源账单', (tester) async {
    late GatedDeleteUiDb db;
    await tester.runAsync(() async {
      db = GatedDeleteUiDb();
    });
    await seedDeleteUi(db);
    final bills = await db.select(db.bills).get();
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '已有分类'));
    await dropdown(tester, 'category-delete-target', '目标一级 / 目标二级');
    await click(tester, deleteKey('category-delete-whole-group'));
    await tester.ensureVisible(confirmation());
    await tester.runAsync(() async {
      await tester.tap(confirmation());
      await db.entered.future.timeout(const Duration(seconds: 3));
      await db.deleteCategory('target-child');
      db.release.complete();
    });
    await finishGate(tester, db);
    expect(find.byType(CategoryDeleteDialog), findsOneWidget);
    expect(find.text('目标分类已变化，请重新选择'), findsOneWidget);
    expect(await db.select(db.bills).get(), bills);
    expect(
      (await db.getAllCategories()).where(
        (c) => c.id == 'source' || c.id == 'child',
      ),
      hasLength(2),
    );
    await disposePage(tester, db);
  });

  for (final kind in [0, 1]) {
    for (final mode in [
      'existing',
      'create-root',
      'create-child',
      'uncategorized',
    ]) {
      testWidgets('类型 $kind 删除整组转移到 $mode，软删除恢复及所有其他字段保留', (tester) async {
        final db = TestAppDatabase();
        await seedDeleteUi(db, kind: kind);
        final before = await db.select(db.bills).get();
        final accounts = await db.getAllAccounts();
        await pumpPage(tester, const CategoriesPage(), db: db);
        await openDeletion(tester, kind: kind);
        expect(find.text('活跃账单 1 笔 · 已删除账单 1 笔'), findsOneWidget);
        expect(find.text('· 待删二级'), findsOneWidget);
        expect(tester.widget<FilledButton>(confirmation()).onPressed, isNull);
        if (mode == 'existing') {
          await click(tester, find.widgetWithText(ChoiceChip, '已有分类'));
          await dropdown(tester, 'category-delete-target', '目标一级 / 目标二级');
        } else if (mode.startsWith('create')) {
          await click(tester, find.widgetWithText(ChoiceChip, '新增分类'));
          if (mode == 'create-child') {
            await dropdown(tester, 'category-delete-new-parent', '目标一级');
          }
          await tester.enterText(deleteKey('category-delete-new-name'), '新去向');
          await click(tester, find.widgetWithText(ChoiceChip, '💰'));
        } else {
          await click(tester, find.widgetWithText(ChoiceChip, '未分类'));
        }
        expect(tester.widget<FilledButton>(confirmation()).onPressed, isNull);
        await click(tester, deleteKey('category-delete-whole-group'));
        await commitClick(tester, confirmation());
        expect(find.byType(AlertDialog), findsNothing);
        final categories = await db.getAllCategories();
        expect(
          categories.where((c) => c.id == 'source' || c.id == 'child'),
          isEmpty,
        );
        final newCategory = categories
            .where((c) => c.name == '新去向')
            .firstOrNull;
        final expectedId = mode == 'existing'
            ? 'target-child'
            : mode == 'uncategorized'
            ? null
            : newCategory!.id;
        if (newCategory != null) {
          expect(
            newCategory.parentId,
            mode == 'create-child' ? 'target' : null,
          );
          expect(newCategory.emoji, '💰');
          expect(newCategory.kind, kind);
        }
        final after = await db.select(db.bills).get();
        for (final original in before) {
          expect(after.singleWhere((b) => b.id == original.id).toJson(), {
            ...original.toJson(),
            'categoryId': expectedId,
          });
        }
        expect(await db.getAllAccounts(), accounts);
        await db.restoreBill('trash');
        expect(
          (await db.getAllBills())
              .singleWhere((b) => b.id == 'trash')
              .categoryId,
          expectedId,
        );
        expect(tester.takeException(), isNull);
        await disposePage(tester, db);
      });
    }
  }

  testWidgets('新增去向填写后取消不写库，返回原编辑窗口', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    final categories = await db.getAllCategories();
    final bills = await db.select(db.bills).get();
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '新增分类'));
    await tester.enterText(deleteKey('category-delete-new-name'), '取消新建');
    await click(tester, find.text('取消').last);
    expect(find.byType(CategoryDeleteDialog), findsNothing);
    expect(find.text('编辑分类'), findsOneWidget);
    expect(await db.getAllCategories(), categories);
    expect(await db.select(db.bills).get(), bills);
    await disposePage(tester, db);
  });

  testWidgets('新去向空名称及同级重名拒绝，保留输入和全部原记录', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    final categories = await db.getAllCategories();
    final bills = await db.select(db.bills).get();
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '新增分类'));
    await click(tester, deleteKey('category-delete-whole-group'));
    await commitClick(tester, confirmation());
    expect(find.text('请填写分类名称'), findsOneWidget);
    await tester.enterText(deleteKey('category-delete-new-name'), ' 目标一级 ');
    await commitClick(tester, confirmation());
    expect(find.text('同级已有同名分类'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(deleteKey('category-delete-new-name'))
          .controller!
          .text,
      ' 目标一级 ',
    );
    expect(await db.getAllCategories(), categories);
    expect(await db.select(db.bills).get(), bills);
    await disposePage(tester, db);
  });

  testWidgets('选择目标消失后禁用确认，可改选未分类', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '已有分类'));
    await dropdown(tester, 'category-delete-target', '目标一级 / 目标二级');
    await click(tester, deleteKey('category-delete-whole-group'));
    await db.deleteCategory('target-child');
    await settleProviders(tester);
    expect(find.text('目标分类已不可用'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirmation()).onPressed, isNull);
    await click(tester, find.widgetWithText(ChoiceChip, '未分类'));
    await commitClick(tester, confirmation());
    expect(find.byType(AlertDialog), findsNothing);
    expect((await db.getAllBills()).single.categoryId, isNull);
    await disposePage(tester, db);
  });

  testWidgets('范围新增账单时整项拒绝，刷新显示新数量并重新确认', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '已有分类'));
    await dropdown(tester, 'category-delete-target', '目标一级 / 目标二级');
    await click(tester, deleteKey('category-delete-whole-group'));
    await db.upsertBill(
      id: 'new',
      type: 0,
      amount: 100,
      categoryId: 'child',
      accountId: 'acc_cash',
      dateMs: 1,
    );
    final before = await db.select(db.bills).get();
    await commitClick(tester, confirmation());
    expect(find.text('分类或账单已变化，请重新确认删除范围'), findsOneWidget);
    expect(await db.select(db.bills).get(), before);
    await commitClick(tester, find.text('刷新删除范围'));
    expect(find.text('活跃账单 2 笔 · 已删除账单 1 笔'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(deleteKey('category-delete-whole-group'))
          .value,
      isFalse,
    );
    expect(tester.widget<FilledButton>(confirmation()).onPressed, isNull);
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: deleteKey('category-delete-target'),
              matching: find.byType(DropdownButton<String>),
            ),
          )
          .value,
      isNull,
    );
    await click(tester, find.widgetWithText(ChoiceChip, '未分类'));
    await click(tester, deleteKey('category-delete-whole-group'));
    await commitClick(tester, confirmation());
    expect((await db.getAllBills()).every((b) => b.categoryId == null), isTrue);
    await disposePage(tester, db);
  });

  testWidgets('新建二级的父级失效时禁止提交，刷新保留名称并回到新一级', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '新增分类'));
    await dropdown(tester, 'category-delete-new-parent', '目标一级');
    await tester.enterText(deleteKey('category-delete-new-name'), '保留新名称');
    final targetPreview = await db.previewCategoryDeletion('target');
    await db.deleteCategoryAndReassign(
      expected: targetPreview,
      destination: const CategoryDeleteDestination.uncategorized(),
      confirmWholeGroup: true,
    );
    await settleProviders(tester);
    expect(tester.widget<FilledButton>(confirmation()).onPressed, isNull);
    expect(find.text('目标一级已不可用'), findsOneWidget);
    await commitClick(tester, find.text('刷新删除范围'));
    expect(
      tester
          .widget<TextField>(deleteKey('category-delete-new-name'))
          .controller!
          .text,
      '保留新名称',
    );
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: deleteKey('category-delete-new-parent'),
              matching: find.byType(DropdownButton<String>),
            ),
          )
          .value,
      '',
    );
    await click(tester, deleteKey('category-delete-whole-group'));
    await commitClick(tester, confirmation());
    final created = (await db.getAllCategories()).singleWhere(
      (c) => c.name == '保留新名称',
    );
    expect(created.parentId, isNull);
    expect((await db.getAllBills()).single.categoryId, created.id);
    await disposePage(tester, db);
  });

  testWidgets('含受保护结算账单明确拒绝，窗口和原数据保留', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    await db.upsertBill(
      id: 'protected',
      type: 1,
      amount: 500,
      categoryId: 'child',
      accountId: 'acc_cash',
      dateMs: 1,
      settlementId: 'settled',
    );
    final before = await db.select(db.bills).get();
    final categories = await db.getAllCategories();
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '未分类'));
    await click(tester, deleteKey('category-delete-whole-group'));
    await commitClick(tester, confirmation());
    expect(find.text('结算账单分类不可更改，请保留该分类'), findsOneWidget);
    expect(find.byType(CategoryDeleteDialog), findsOneWidget);
    expect(await db.select(db.bills).get(), before);
    expect(await db.getAllCategories(), categories);
    await disposePage(tester, db);
  });

  testWidgets('双击只提交一次，提交中系统返回不能关闭窗口', (tester) async {
    late GatedDeleteUiDb db;
    await tester.runAsync(() async {
      db = GatedDeleteUiDb();
    });
    await seedDeleteUi(db);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '未分类'));
    await click(tester, deleteKey('category-delete-whole-group'));
    await tester.ensureVisible(confirmation());
    await tester.runAsync(() async {
      await tester.tap(confirmation());
      await db.entered.future.timeout(const Duration(seconds: 3));
      await tester.tap(confirmation());
    });
    await tester.pump();
    expect(db.calls, 1);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(CategoryDeleteDialog), findsOneWidget);
    db.release.complete();
    await finishGate(tester, db);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('分类管理'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('删除转移后明细与已打开详情实时刷新路径', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    await pumpPage(tester, const BillsPage(), db: db);
    await click(tester, find.text('保留active'));
    Navigator.of(tester.element(find.text('账单详情')))
        .push(MaterialPageRoute(builder: (_) => const CategoriesPage()));
    await settleProviders(tester);
    await openDeletion(tester);
    await click(tester, find.widgetWithText(ChoiceChip, '已有分类'));
    await dropdown(tester, 'category-delete-target', '目标一级 / 目标二级');
    await click(tester, deleteKey('category-delete-whole-group'));
    await commitClick(tester, confirmation());
    Navigator.of(tester.element(find.text('分类管理'))).pop();
    await settleProviders(tester);
    expect(
      find.descendant(
        of: find.byType(BillDetailPage),
        matching: find.textContaining('目标一级 / 目标二级'),
      ),
      findsOneWidget,
    );
    Navigator.of(tester.element(find.text('账单详情'))).pop();
    await settleProviders(tester);
    expect(find.textContaining('目标一级 / 目标二级'), findsOneWidget);
    await disposePage(tester, db);
  });

  for (final kind in [0, 1]) {
    testWidgets('类型 $kind 未分类编辑只改备注仍为未分类，也可主动选分类', (tester) async {
      final db = TestAppDatabase();
      await seedDeleteUi(db, kind: kind);
      final preview = await db.previewCategoryDeletion('source');
      await db.deleteCategoryAndReassign(
        expected: preview,
        destination: const CategoryDeleteDestination.uncategorized(),
        confirmWholeGroup: true,
      );
      final bill = (await db.getAllBills()).single;
      await pumpPage(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => EditBillPage(bill: bill))),
            child: const Text('编辑'),
          ),
        ),
        db: db,
      );
      await click(tester, find.text('编辑'));
      expect(find.text('未分类，可点选分类'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '只改备注');
      tester.testTextInput.hide();
      await commitClick(tester, find.text('保存'));
      final saved = (await db.getAllBills()).single;
      expect(saved.categoryId, isNull);
      expect(saved.note, '只改备注');
      expect(saved.amount, bill.amount);
      await click(tester, find.text('编辑'));
      await click(tester, deleteKey('category-root-target'));
      await commitClick(tester, find.text('保存'));
      expect((await db.getAllBills()).single.categoryId, 'target');
      await disposePage(tester, db);
    });
  }

  testWidgets('旧记账窗口不能把转移后的分类覆盖成旧选择或默认一级', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    final original = (await db.getAllBills()).single;
    await pumpPage(tester, EditBillPage(bill: original), db: db);
    final preview = await db.previewCategoryDeletion('source');
    await db.deleteCategoryAndReassign(
      expected: preview,
      destination: const CategoryDeleteDestination.uncategorized(),
      confirmWholeGroup: true,
    );
    final transferred = await db.select(db.bills).get();
    await settleProviders(tester);
    await tester.enterText(find.byType(TextField), '旧页面备注');
    tester.testTextInput.hide();
    await commitClick(tester, find.text('保存'));
    expect(find.text('账单分类已转移，请返回重新打开'), findsOneWidget);
    expect(await db.select(db.bills).get(), transferred);
    expect(find.byType(EditBillPage), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('旧分类编辑窗口不能重新创建被删除的原分类ID', (tester) async {
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await click(tester, deleteKey('category-row-source'));
    final preview = await db.previewCategoryDeletion('source');
    await db.deleteCategoryAndReassign(
      expected: preview,
      destination: const CategoryDeleteDestination.uncategorized(),
      confirmWholeGroup: true,
    );
    await tester.enterText(find.byType(TextField), '不应重建');
    await commitClick(tester, find.text('保存'));
    expect(find.text('分类已变化，请关闭后重新打开'), findsOneWidget);
    expect(
      (await db.getAllCategories()).where((c) => c.id == 'source'),
      isEmpty,
    );
    expect((await db.getAllBills()).single.categoryId, isNull);
    await disposePage(tester, db);
  });

  testWidgets('320宽大字体和键盘下新建转移窗口可滚动且无溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = TestAppDatabase();
    await seedDeleteUi(db);
    await db.upsertCategory(
      id: 'source',
      name: '很长的待删除一级分类' * 4,
      emoji: '☕',
      kind: 0,
      sort: 0,
    );
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openDeletion(tester);
    expect(
      MediaQuery.textScalerOf(tester.element(find.byType(CategoryDeleteDialog)))
          .scale(10),
      18,
    );
    await click(tester, find.widgetWithText(ChoiceChip, '新增分类'));
    await tester.ensureVisible(deleteKey('category-delete-new-name'));
    await tester.enterText(
      deleteKey('category-delete-new-name'),
      '很长的新分类名称' * 4,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await click(tester, find.text('取消').last);
    expect(find.byType(CategoryDeleteDialog), findsNothing);
    await disposePage(tester, db);
  });
}
