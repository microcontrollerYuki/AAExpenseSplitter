import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/category_hierarchy.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/categories_page.dart';

import '../helpers/test_support.dart';

Finder moveKey(String value) => find.byKey(ValueKey(value));

Future<void> addMoveCategory(
  AppDatabase db,
  String id,
  String name, {
  int kind = 0,
  int sort = 0,
  String? parent,
}) => db.upsertCategory(
  id: id,
  name: name,
  emoji: '🍜',
  kind: kind,
  sort: sort,
  parentId: parent,
);

Future<void> seedMoveCategories(
  AppDatabase db, {
  int kind = 0,
  bool withTarget = true,
}) async {
  await db.getAllAccounts();
  await db.delete(db.categories).go();
  await addMoveCategory(db, 'source', '原一级', kind: kind);
  if (withTarget) {
    await addMoveCategory(db, 'target', '目标一级', kind: kind, sort: 1);
  }
  await addMoveCategory(
    db,
    'child',
    '待迁二级',
    kind: kind,
    sort: 4,
    parent: 'source',
  );
}

Future<void> openMove(WidgetTester tester, {int kind = 0}) async {
  if (kind == 1) {
    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(moveKey('category-move-child'));
  await tester.tap(moveKey('category-move-child'));
  await tester.pumpAndSettle();
  expect(find.text('迁移二级分类'), findsOneWidget);
}

Future<void> chooseMoveTarget(
  WidgetTester tester, {
  String name = '目标一级',
}) async {
  await tester.ensureVisible(moveKey('category-move-parent'));
  await tester.tap(moveKey('category-move-parent'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Finder moveConfirmation() => find.widgetWithText(FilledButton, '迁移');

Future<void> confirmMove(WidgetTester tester) async {
  await tester.ensureVisible(moveConfirmation());
  await tester.runAsync(() async {
    await tester.tap(moveConfirmation());
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await settleProviders(tester);
}

// Drift 的事务回滚和 Provider 通知可能排入测试时钟，交替推进两种时钟。
Future<void> finishGatedMove(WidgetTester tester, GatedMoveDatabase db) async {
  for (var i = 0; i < 40 && !db.finished.isCompleted; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(db.finished.isCompleted, isTrue, reason: '迁移应在两秒内结束');
  await settleProviders(tester);
}

/// 在真实异步区暂停提交，制造选择之后、事务之前的并发改动。
class GatedMoveDatabase extends TestAppDatabase {
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _release = Completer<void>();
  int moveCalls = 0;
  String? submittedParent;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<void> moveSubcategory({
    required String id,
    required String expectedParentId,
    required String targetParentId,
  }) async {
    moveCalls++;
    submittedParent = expectedParentId;
    if (!entered.isCompleted) entered.complete();
    try {
      await _release.future;
      await super.moveSubcategory(
        id: id,
        expectedParentId: expectedParentId,
        targetParentId: targetParentId,
      );
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }

  Future<void> moveFromOtherEntry(String target) => super.moveSubcategory(
    id: 'child',
    expectedParentId: 'source',
    targetParentId: target,
  );
}

void main() {
  for (final kind in [0, 1]) {
    testWidgets('类型 $kind 迁移刷新归属及详情明细路径，全部账单字段不变', (tester) async {
      final db = TestAppDatabase();
      await seedMoveCategories(db, kind: kind);
      await addMoveCategory(
        db,
        'target-existing',
        '目标原有二级',
        kind: kind,
        sort: 7,
        parent: 'target',
      );
      await db.upsertBill(
        id: 'active',
        type: kind,
        amount: 1234,
        categoryId: 'child',
        accountId: 'acc_wechat',
        dateMs: DateTime.now().millisecondsSinceEpoch,
        note: '迁移保留账单',
        createdAt: 77,
      );
      await db.upsertBill(
        id: 'deleted',
        type: kind,
        amount: 5678,
        categoryId: 'child',
        accountId: 'acc_cash',
        dateMs: 1234567890000,
        note: '软删除引用也保留',
        createdAt: 88,
      );
      await db.softDeleteBill('deleted');
      final beforeBills = await db.select(db.bills).get();
      final beforeCategories = {
        for (final category in await db.getAllCategories())
          category.id: category,
      };
      await pumpPage(tester, const BillsPage(), db: db);
      expect(find.textContaining('原一级 / 待迁二级'), findsOneWidget);
      await tester.tap(find.text('迁移保留账单'));
      await settleProviders(tester);
      Navigator.of(tester.element(find.text('账单详情')))
          .push(MaterialPageRoute(builder: (_) => const CategoriesPage()));
      await settleProviders(tester);
      await openMove(tester, kind: kind);
      expect(find.text('当前分类：原一级 / 待迁二级'), findsOneWidget);
      expect(tester.widget<FilledButton>(moveConfirmation()).onPressed, isNull);
      await chooseMoveTarget(tester);
      await confirmMove(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.descendant(
          of: moveKey('category-children-target'),
          matching: moveKey('category-row-child'),
        ),
        findsOneWidget,
      );
      expect(moveKey('category-children-source'), findsNothing);
      final afterCategories = await db.getAllCategories();
      final moved = afterCategories.singleWhere(
        (category) => category.id == 'child',
      );
      expect(moved.parentId, 'target');
      expect(moved.sort, 8);
      expect(moved.kind, kind);
      for (final category in afterCategories.where(
        (category) => category.id != 'child',
      )) {
        expect(category, beforeCategories[category.id]);
      }
      expect(CategoryHierarchy(afterCategories).pathOf('child'), '目标一级 / 待迁二级');
      expect(await db.select(db.bills).get(), beforeBills);
      Navigator.of(tester.element(find.text('分类管理'))).pop();
      await settleProviders(tester);
      expect(
        find.descendant(
          of: find.byType(BillDetailPage),
          matching: find.textContaining('目标一级 / 待迁二级'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('原一级 / 待迁二级'), findsNothing);
      Navigator.of(tester.element(find.text('账单详情'))).pop();
      await settleProviders(tester);
      expect(find.textContaining('目标一级 / 待迁二级'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('迁移目标只列其他同类型有效一级，取消不改变分类', (tester) async {
    final db = TestAppDatabase();
    await seedMoveCategories(db);
    await addMoveCategory(db, 'income', '收入一级', kind: 1);
    await addMoveCategory(db, 'internal', '内部分类', kind: 2);
    await addMoveCategory(db, 'other-child', '其他二级', parent: 'target');
    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: 'orphan',
            name: '异常孤儿',
            emoji: '🍜',
            kind: 0,
            parentId: const Value('missing'),
          ),
        );
    final before = await db.getAllCategories();
    await pumpPage(tester, const CategoriesPage(), db: db);
    expect(moveKey('category-move-source'), findsNothing);
    await openMove(tester);
    final dropdown = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: moveKey('category-move-parent'),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    expect(dropdown.items!.map((item) => item.value).toList(), ['target']);
    expect(tester.widget<FilledButton>(moveConfirmation()).onPressed, isNull);
    await chooseMoveTarget(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(await db.getAllCategories(), before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('无其他同类型一级时说明新增途径并禁用迁移', (tester) async {
    final db = TestAppDatabase();
    await seedMoveCategories(db, withTarget: false);
    await addMoveCategory(db, 'income', '收入一级', kind: 1);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openMove(tester);
    expect(find.text('请先新增另一个同类型一级分类'), findsOneWidget);
    expect(tester.widget<FilledButton>(moveConfirmation()).onPressed, isNull);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            moveKey('category-move-parent'),
          )
          .onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('目标下同名二级在窗口内报错，保留选择且不写入', (tester) async {
    final db = TestAppDatabase();
    await seedMoveCategories(db);
    await addMoveCategory(db, 'duplicate', '待迁二级', parent: 'target');
    final before = await db.getAllCategories();
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openMove(tester);
    await chooseMoveTarget(tester);
    await confirmMove(tester);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('目标一级下已有同名二级分类'),
      ),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester
          .state<FormFieldState<String>>(moveKey('category-move-parent'))
          .value,
      'target',
    );
    expect(await db.getAllCategories(), before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('已选目标被删除时显示不可用并禁用，不静默替换其他一级', (tester) async {
    final db = TestAppDatabase();
    await seedMoveCategories(db);
    await addMoveCategory(db, 'alternative', '另一个可用一级', sort: 2);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openMove(tester);
    await chooseMoveTarget(tester);
    await tester.runAsync(() => db.deleteCategory('target'));
    await settleProviders(tester);
    expect(find.text('目标一级已不可用'), findsOneWidget);
    expect(tester.widget<FilledButton>(moveConfirmation()).onPressed, isNull);
    expect(
      tester
          .state<FormFieldState<String>>(moveKey('category-move-parent'))
          .value,
      'target',
    );
    expect(
      (await db.getAllCategories())
          .singleWhere((category) => category.id == 'child')
          .parentId,
      'source',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('提交途中目标被删除由事务拒绝，错误留在窗口且只提交一次', (tester) async {
    late GatedMoveDatabase db;
    // 信号也在真实 Zone 创建，避免等待 fake microtask。
    await tester.runAsync(() async {
      db = GatedMoveDatabase();
    });
    addTearDown(db.release);
    await seedMoveCategories(db);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openMove(tester);
    await chooseMoveTarget(tester);
    await tester.runAsync(() async {
      await tester.tap(moveConfirmation());
      await db.entered.future.timeout(const Duration(seconds: 3));
      try {
        // 第一次事件后尚未重建按钮，业务 busy 保护仍应拦住重复事件。
        await tester.tap(moveConfirmation());
        await db.deleteCategory('target');
      } finally {
        db.release();
      }
    });
    await finishGatedMove(tester, db);
    expect(db.moveCalls, 1);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('目标必须是同类型的有效一级分类'),
      ),
      findsOneWidget,
    );
    expect(
      (await db.getAllCategories())
          .singleWhere((category) => category.id == 'child')
          .parentId,
      'source',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('提交途中其他入口迁移来源后拒绝陈旧请求，不覆盖新归属', (tester) async {
    late GatedMoveDatabase db;
    // 信号也在真实 Zone 创建，避免等待 fake microtask。
    await tester.runAsync(() async {
      db = GatedMoveDatabase();
    });
    addTearDown(db.release);
    await seedMoveCategories(db);
    await addMoveCategory(db, 'concurrent-target', '另一入口目标', sort: 2);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openMove(tester);
    await chooseMoveTarget(tester);
    await tester.runAsync(() async {
      await tester.tap(moveConfirmation());
      await db.entered.future.timeout(const Duration(seconds: 3));
      try {
        await db.moveFromOtherEntry('concurrent-target');
      } finally {
        db.release();
      }
    });
    await finishGatedMove(tester, db);
    expect(db.submittedParent, 'source');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('分类归属已变化，请刷新后重试'),
      ),
      findsOneWidget,
    );
    expect(
      (await db.getAllCategories())
          .singleWhere((category) => category.id == 'child')
          .parentId,
      'concurrent-target',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('迁移等待时双击仅提交一次，系统返回后完成不误关底层页面', (tester) async {
    late GatedMoveDatabase db;
    // 信号也在真实 Zone 创建，避免等待 fake microtask。
    await tester.runAsync(() async {
      db = GatedMoveDatabase();
    });
    addTearDown(db.release);
    await seedMoveCategories(db);
    await pumpPage(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const CategoriesPage())),
          child: const Text('打开分类管理'),
        ),
      ),
      db: db,
    );
    await tester.tap(find.text('打开分类管理'));
    await settleProviders(tester);
    await openMove(tester);
    await chooseMoveTarget(tester);
    await tester.runAsync(() async {
      await tester.tap(moveConfirmation());
      await tester.tap(moveConfirmation());
      await db.entered.future.timeout(const Duration(seconds: 3));
    });
    await tester.pump();
    expect(db.moveCalls, 1);
    expect(tester.widget<FilledButton>(moveConfirmation()).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('分类管理'), findsOneWidget);
    await tester.runAsync(() async {
      db.release();
    });
    await finishGatedMove(tester, db);
    expect(find.text('分类管理'), findsOneWidget);
    expect(find.text('打开分类管理'), findsNothing);
    expect(
      (await db.getAllCategories())
          .singleWhere((category) => category.id == 'child')
          .parentId,
      'target',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('窄屏大字体长路径及长目标名可滚动选择并迁移，无溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = TestAppDatabase();
    await seedMoveCategories(db);
    final sourceName = '很长的来源一级分类' * 5;
    final targetName = '很长的目标一级分类' * 5;
    final childName = '很长的二级分类名称' * 5;
    await addMoveCategory(db, 'source', sourceName);
    await addMoveCategory(db, 'target', targetName, sort: 1);
    await addMoveCategory(db, 'child', childName, parent: 'source', sort: 4);
    await pumpPage(tester, const CategoriesPage(), db: db);
    await openMove(tester);
    expect(find.text('当前分类：$sourceName / $childName'), findsOneWidget);
    await chooseMoveTarget(tester, name: targetName);
    await confirmMove(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      (await db.getAllCategories())
          .singleWhere((category) => category.id == 'child')
          .parentId,
      'target',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
