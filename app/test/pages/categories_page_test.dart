import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aa_expense_splitter/pages/categories_page.dart';

import '../helpers/test_support.dart';

Future<void> act(WidgetTester tester, String label) async {
  await tester.runAsync(() async {
    await tester.tap(find.text(label));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await settleProviders(tester);
}

void main() {
  testWidgets('普通分类新增改名换图标及删除仍可用', (tester) async {
    final db = await pumpPage(tester, const CategoriesPage());
    await tester.tap(find.text('新增分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '自定义测试');
    await act(tester, '保存');
    expect(find.byType(AlertDialog), findsNothing);
    await tester.scrollUntilVisible(
      find.text('自定义测试'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(ReorderableListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('自定义测试'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '修改后');
    await tester.tap(find.text('🍜').last);
    await act(tester, '保存');
    final category = (await db.getAllCategories()).singleWhere(
      (c) => c.name == '修改后',
    );
    expect(category.emoji, '🍜');
    expect(category.parentId, isNull);
    await tester.tap(find.text('修改后'));
    await tester.pumpAndSettle();
    await act(tester, '删除');
    await tester.tap(find.widgetWithText(ChoiceChip, '未分类'));
    await tester.pumpAndSettle();
    await act(tester, '确认转移并删除');
    expect(find.text('修改后'), findsNothing);
    expect(await db.getAllCategories(), isNot(contains(category)));
    await disposePage(tester, db);
  });

  testWidgets('同级重名保存被拒绝且对话框保留输入', (tester) async {
    final db = await pumpPage(tester, const CategoriesPage());
    final before = await db.getAllCategories();
    await tester.tap(find.text('新增分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' 餐饮 ');
    await act(tester, '保存');
    expect(find.text('同级已有同名分类'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      ' 餐饮 ',
    );
    expect(await db.getAllCategories(), before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('有子级的一级删除列出范围，未确认前保留原组', (tester) async {
    final db = TestAppDatabase();
    await db.upsertCategory(
      id: 'parent',
      name: '测试父级',
      emoji: '🍜',
      kind: 0,
      sort: -2,
    );
    await db.upsertCategory(
      id: 'child',
      name: '测试子级',
      emoji: '☕',
      kind: 0,
      sort: -1,
      parentId: 'parent',
    );
    await pumpPage(tester, const CategoriesPage(), db: db);
    await tester.tap(find.text('测试父级'));
    await tester.pumpAndSettle();
    await act(tester, '删除');
    expect(find.text('同时删除以下二级分类：'), findsOneWidget);
    expect(find.text('· 测试子级'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    expect(
      (await db.getAllCategories()).where((c) => c.id == 'parent'),
      hasLength(1),
    );
    await disposePage(tester, db);
  });

  testWidgets('删除范围显示软删除账单，确认之前不写库', (tester) async {
    final db = TestAppDatabase();
    await db.upsertBill(
      id: 'deleted',
      type: 0,
      amount: 100,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: 1,
    );
    await db.softDeleteBill('deleted');
    await pumpPage(tester, const CategoriesPage(), db: db);
    await tester.tap(find.text('餐饮'));
    await tester.pumpAndSettle();
    await act(tester, '删除');
    expect(find.text('活跃账单 0 笔 · 已删除账单 1 笔'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('分类列表变化后拒绝陈旧排序并提示', (tester) async {
    final db = TestAppDatabase();
    await db.upsertCategory(
      id: 'child',
      name: '测试子级',
      emoji: '☕',
      kind: 0,
      sort: -1,
      parentId: 'cat_food',
    );
    await pumpPage(tester, const CategoriesPage(), db: db);
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView).first,
    );
    await db.upsertCategory(
      id: 'new-root',
      name: '新一级',
      emoji: '🍜',
      kind: 0,
      sort: 99,
    );
    final before = await db.getAllCategories();
    await tester.runAsync(() async {
      list.onReorderItem!(0, 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settleProviders(tester);
    expect(find.text('分类列表已变化，请刷新后重试'), findsOneWidget);
    expect(await db.getAllCategories(), before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
