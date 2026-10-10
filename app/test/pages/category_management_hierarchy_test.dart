import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/categories_page.dart';
import 'package:aa_expense_splitter/providers.dart';

import '../helpers/test_support.dart';

Future<void> save(WidgetTester tester, {String action = '保存'}) async {
  await tester.runAsync(() async {
    await tester.tap(find.text(action));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await settleProviders(tester);
}

Future<void> add(
  AppDatabase db,
  String id,
  String name, {
  int kind = 0,
  String? parent,
  int sort = -1,
}) => db.upsertCategory(
  id: id,
  name: name,
  emoji: '🍜',
  kind: kind,
  sort: sort,
  parentId: parent,
);

Future<void> tab(WidgetTester tester, int kind) async {
  if (kind == 0) return;
  await tester.tap(find.text(kind == 1 ? '收入' : '不计收支'));
  await tester.pumpAndSettle();
}

Future<void> reorder(
  WidgetTester tester,
  String listKey,
  int from,
  int to,
) async {
  final list = tester.widget<ReorderableListView>(
    find.byKey(ValueKey(listKey)),
  );
  await tester.runAsync(() async {
    list.onReorderItem!(from, to);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await settleProviders(tester);
}

void main() {
  testWidgets('新增期间父级被删除，选择窗口安全回退并拒绝孤儿写入', (tester) async {
    final db = TestAppDatabase();
    await add(db, 'pa', '父甲');
    await pumpPage(tester, const CategoriesPage(), db: db);
    await tester.tap(find.byKey(const ValueKey('category-add-child-pa')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => db.deleteCategory('pa'));
    await settleProviders(tester);
    expect(find.text('父级已不可用'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '新二级');
    await save(tester);
    expect(find.text('二级分类必须属于同类型的有效一级分类'), findsOneWidget);
    expect(
      (await db.getAllCategories()).where((c) => c.name == '新二级'),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('预置一级改名换图标保留预置标志和原 ID', (tester) async {
    final db = await pumpPage(tester, const CategoriesPage());
    await tester.tap(find.text('餐饮'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '食物饮品');
    await save(tester);
    final category = (await db.getAllCategories()).singleWhere(
      (c) => c.id == 'cat_food',
    );
    expect(category.name, '食物饮品');
    expect(category.isPreset, isTrue);
    expect(category.parentId, isNull);
    await disposePage(tester, db);
  });

  testWidgets('二级拖动手柄的真实手势改变同级顺序，不触发一级拖动', (tester) async {
    final db = TestAppDatabase();
    await add(db, 'pa', '父甲', sort: -2);
    await add(db, 'a1', '甲一', parent: 'pa', sort: 5);
    await add(db, 'a2', '甲二', parent: 'pa', sort: 8);
    await pumpPage(tester, const CategoriesPage(), db: db);
    final rootBefore = (await db.getAllCategories())
        .where((c) => c.parentId == null)
        .toList();
    final handle = find.byKey(const ValueKey('category-drag-a1'));
    final target = tester.getCenter(
      find.byKey(const ValueKey('category-drag-a2')),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 600));
    // 拖动项的顶部需越过最后一行，才能插入到第二项之后。
    await gesture.moveTo(target + const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      await gesture.up();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settleProviders(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await settleProviders(tester);
    final rows = await db.getAllCategories();
    expect(rows.singleWhere((c) => c.id == 'a2').sort, 0);
    expect(rows.singleWhere((c) => c.id == 'a1').sort, 1);
    expect(rows.where((c) => c.parentId == null).toList(), rootBefore);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final kind in [0, 1]) {
    testWidgets('类型 $kind 一级旁新增二级、编辑保留归属且不提供三级入口', (tester) async {
      final db = TestAppDatabase();
      await add(db, 'parent', '测试父级', kind: kind);
      await pumpPage(tester, const CategoriesPage(), db: db);
      await tab(tester, kind);
      await tester.tap(find.byKey(const ValueKey('category-add-child-parent')));
      await tester.pumpAndSettle();
      expect(find.text('新增二级分类'), findsOneWidget);
      expect(find.text('测试父级').last, findsOneWidget);
      await tester.enterText(find.byType(TextField), '测试二级');
      await save(tester);
      expect(find.text('测试二级'), findsOneWidget);
      final child = (await db.getAllCategories()).singleWhere(
        (c) => c.name == '测试二级',
      );
      expect(child.parentId, 'parent');
      expect(child.kind, kind);
      expect(
        find.byKey(ValueKey('category-add-child-${child.id}')),
        findsNothing,
      );
      await tester.tap(find.text('测试二级'));
      await tester.pumpAndSettle();
      expect(find.text('所属一级：测试父级'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await tester.enterText(find.byType(TextField), '改名二级');
      await tester.tap(find.text('☕').last);
      await save(tester);
      final edited = (await db.getAllCategories()).singleWhere(
        (c) => c.id == child.id,
      );
      expect(edited.name, '改名二级');
      expect(edited.emoji, '☕');
      expect(edited.parentId, 'parent');
      await disposePage(tester, db);
    });

    testWidgets('类型 $kind 新增窗口选择一级、跨父同名允许且新项排在同级末尾', (tester) async {
      final db = TestAppDatabase();
      await add(db, 'pa', '父甲', kind: kind);
      await add(db, 'pb', '父乙', kind: kind);
      await add(db, 'a', '同名二级', kind: kind, parent: 'pa', sort: 150);
      await add(db, 'b', '其他二级', kind: kind, parent: 'pb', sort: 200);
      await pumpPage(tester, const CategoriesPage(), db: db);
      await tab(tester, kind);
      await tester.tap(find.text('新增分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('父乙').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '同名二级');
      await save(tester);
      final rows = await db.getAllCategories();
      final added = rows.singleWhere(
        (c) => c.name == '同名二级' && c.parentId == 'pb',
      );
      expect(added.kind, kind);
      expect(added.sort, 201);
      expect(rows.singleWhere((c) => c.id == 'a').parentId, 'pa');
      await disposePage(tester, db);
    });

    testWidgets('类型 $kind 二级与一级排序互不影响，不改变其他父级或类型', (tester) async {
      final db = TestAppDatabase();
      await add(db, 'pa', '父甲', kind: kind, sort: -2);
      await add(db, 'pb', '父乙', kind: kind, sort: -1);
      await add(db, 'a1', '甲一', kind: kind, parent: 'pa', sort: 5);
      await add(db, 'a2', '甲二', kind: kind, parent: 'pa', sort: 8);
      await add(db, 'b1', '乙一', kind: kind, parent: 'pb', sort: 9);
      await pumpPage(tester, const CategoriesPage(), db: db);
      await tab(tester, kind);
      final before = {for (final c in await db.getAllCategories()) c.id: c};
      await reorder(tester, 'category-children-pa', 1, 0);
      final childrenSorted = {
        for (final c in await db.getAllCategories()) c.id: c,
      };
      expect(childrenSorted['a2']!.sort, 0);
      expect(childrenSorted['a1']!.sort, 1);
      for (final id in before.keys.where((id) => id != 'a1' && id != 'a2')) {
        expect(childrenSorted[id], before[id]);
      }
      await reorder(tester, 'category-roots-$kind', 1, 0);
      final rootsSorted = {
        for (final c in await db.getAllCategories()) c.id: c,
      };
      expect(rootsSorted['pb']!.sort, 0);
      expect(rootsSorted['pa']!.sort, 1);
      for (final c in childrenSorted.values.where(
        (c) => c.parentId != null || c.kind != kind,
      )) {
        expect(rootsSorted[c.id], c);
      }
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('空名称、路径分隔符和同级重名在窗口内提示并保留输入', (tester) async {
    final db = TestAppDatabase();
    await add(db, 'pa', '父甲');
    await add(db, 'a', '早餐', parent: 'pa');
    await pumpPage(tester, const CategoriesPage(), db: db);
    final before = await db.getAllCategories();
    await tester.tap(find.byKey(const ValueKey('category-add-child-pa')));
    await tester.pumpAndSettle();
    for (final entry in {
      '  ': '请填写分类名称',
      '餐饮 / 早餐': '分类名称不能包含路径分隔符「 / 」',
      ' 早餐 ': '同级已有同名分类',
    }.entries) {
      await tester.enterText(find.byType(TextField), entry.key);
      await save(tester);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(entry.value),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        entry.key,
      );
      expect(await db.getAllCategories(), before);
    }
    await disposePage(tester, db);
  });

  testWidgets('先删未引用二级才能删一级，引用二级的软删除账单仍受保护', (tester) async {
    final db = TestAppDatabase();
    await add(db, 'pa', '父甲');
    await add(db, 'a', '早餐', parent: 'pa');
    await add(db, 'free', '空二级', parent: 'pa');
    await db.upsertBill(
      id: 'bill',
      type: 0,
      amount: 100,
      categoryId: 'a',
      accountId: 'acc_cash',
      dateMs: 1,
    );
    await db.softDeleteBill('bill');
    await pumpPage(tester, const CategoriesPage(), db: db);
    await tester.tap(find.text('父甲'));
    await tester.pumpAndSettle();
    await save(tester, action: '删除');
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('请先删除该分类下的二级分类'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('早餐'));
    await tester.pumpAndSettle();
    await save(tester, action: '删除');
    expect(find.text('该分类已有 1 笔账单（含已删除），无法删除（可改名继续用）'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('空二级'));
    await tester.pumpAndSettle();
    await save(tester, action: '删除');
    expect((await db.getAllCategories()).where((c) => c.id == 'free'), isEmpty);
    expect(
      (await db.getAllCategories()).where((c) => c.id == 'a'),
      hasLength(1),
    );
    await disposePage(tester, db);
  });

  testWidgets('窄屏及软键盘下长名称的新增窗口可滚动保存，无溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final db = TestAppDatabase();
    final longName = '很长的一级分类名称' * 5;
    await add(db, 'pa', longName);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await tester.tap(find.byKey(const ValueKey('category-add-child-pa')));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '长二级名称' * 8);
    await tester.ensureVisible(find.text('保存'));
    await save(tester);
    expect(
      (await db.getAllCategories()).where((c) => c.parentId == 'pa'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('异常旧分类单独回退展示，不提供新增二级或拖动且不混入正常排序', (tester) async {
    final db = TestAppDatabase();
    await db.getAllCategories();
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: 'orphan',
            name: '孤儿分类',
            emoji: '🍜',
            kind: 0,
            parentId: const Value('missing'),
          ),
        );
    await pumpPage(tester, const CategoriesPage(), db: db);
    await tester.scrollUntilVisible(
      find.text('孤儿分类'),
      250,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('category-roots-0')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('孤儿分类'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('category-add-child-orphan')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('category-drag-orphan')), findsNothing);
    final old = (await db.getAllCategories()).singleWhere(
      (c) => c.id == 'orphan',
    );
    await reorder(tester, 'category-roots-0', 0, 1);
    expect(
      (await db.getAllCategories()).singleWhere((c) => c.id == 'orphan'),
      old,
    );
    await disposePage(tester, db);
  });

  testWidgets('空分类及不计收支不提供二级入口，空态可继续新增一级', (tester) async {
    final db = await pumpPage(
      tester,
      const CategoriesPage(),
      overrides: [
        categoriesProvider.overrideWith((ref) => Stream.value(<Category>[])),
      ],
    );
    expect(find.text('暂无分类，点右下角新增'), findsOneWidget);
    await tab(tester, 2);
    await tester.tap(find.text('新增分类'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.enterText(find.byType(TextField), '内部测试');
    await save(tester);
    final added = (await db.getAllCategories()).singleWhere(
      (c) => c.name == '内部测试',
    );
    expect(added.kind, 2);
    expect(added.parentId, isNull);
    await disposePage(tester, db);
  });
}
