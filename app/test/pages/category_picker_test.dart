import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/widgets/category_picker.dart';

import '../helpers/test_support.dart';

Future<TestAppDatabase> seed() async {
  final db = TestAppDatabase();
  await db.getAllAccounts();
  for (final kind in [0, 1]) {
    for (final row in [
      (id: 'p$kind', name: '父$kind', parent: null, sort: -30),
      (id: 'q$kind', name: '另一父$kind', parent: null, sort: -20),
      (id: 'c$kind', name: '共同子名', parent: 'p$kind', sort: -100),
      (id: 'd$kind', name: '共同子名', parent: 'q$kind', sort: -100),
    ]) {
      await db.upsertCategory(
        id: row.id,
        name: row.name,
        emoji: '🍜',
        kind: kind,
        sort: row.sort,
        parentId: row.parent,
      );
    }
  }
  return db;
}

Finder key(String value) => find.byKey(ValueKey(value));

void expectSelected(WidgetTester tester, String cellKey, bool selected) {
  final semantics = find.descendant(
    of: key(cellKey),
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.selected != null,
    ),
    matchRoot: true,
  );
  expect(semantics, findsOneWidget);
  expect(tester.widget<Semantics>(semantics).properties.selected, selected);
}

Category fixtureCategory(String id, int sort, {String? parent, String? name}) =>
    Category(
      id: id,
      parentId: parent,
      name: name ?? id,
      emoji: '🍜',
      kind: 0,
      sort: sort,
      isPreset: false,
    );

Future<void> pumpPicker(
  WidgetTester tester,
  List<Category> categories,
  String initialId,
) async {
  var selectedId = initialId;
  await tester.pumpWidget(
    localizedApp(
      StatefulBuilder(
        builder: (context, setState) => CategoryPicker(
          categories: categories,
          kind: 0,
          selectedId: selectedId,
          onSelected: (id) => setState(() => selectedId = id),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await settleProviders(tester);
}

Future<void> save(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('保存'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await settleProviders(tester);
}

Future<void> openEditor(
  WidgetTester tester,
  TestAppDatabase db, {
  Bill? bill,
}) => pumpPage(
  tester,
  Builder(
    builder: (context) => TextButton(
      onPressed: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => EditBillPage(bill: bill))),
      child: const Text('开始'),
    ),
  ),
  db: db,
).then((_) => tap(tester, find.text('开始')));

void main() {
  for (final kind in [0, 1]) {
    for (final child in [false, true]) {
      testWidgets('$kind ${child ? '二级' : '一级直接'}记账保存正确 ID 和其他字段', (
        tester,
      ) async {
        final db = await seed();
        await openEditor(tester, db);
        if (kind == 1) await tap(tester, find.text('收入'));
        expect(key('category-root-c$kind'), findsNothing);
        expect(key('category-root-d$kind'), findsNothing);
        expect(key('category-child-panel-p$kind'), findsOneWidget);
        expectSelected(tester, 'category-root-p$kind', true);
        if (child) await tap(tester, key('category-child-c$kind'));
        await tester.enterText(find.byType(TextField), '保留备注');
        tester.testTextInput.hide();
        await tester.pump();
        await tap(tester, find.text('5'));
        await save(tester);
        final bill = (await db.getAllBills()).single;
        expect(bill.type, kind);
        expect(bill.categoryId, child ? 'c$kind' : 'p$kind');
        expect(bill.amount, 500);
        expect(bill.note, '保留备注');
        expect(bill.accountId, 'acc_cash');
        expect(bill.aaGroupId, isNull);
        await disposePage(tester, db);
      });
    }
    testWidgets('$kind 编辑二级回显，换一级不串二级且保留金额账户日期备注', (tester) async {
      final db = await seed();
      await db.upsertBill(
        id: 'edit',
        type: kind,
        amount: 1234,
        categoryId: 'c$kind',
        accountId: 'acc_wechat',
        dateMs: 1234567890000,
        note: '原备注',
        createdAt: 77,
      );
      final before = (await db.getAllBills()).single;
      await pumpPage(tester, BillDetailPage(bill: before), db: db);
      expect(find.textContaining('父$kind / 共同子名'), findsOneWidget);
      await tap(tester, find.text('修改'));
      expect(find.text('父$kind-共同子名'), findsOneWidget);
      expect(find.byTooltip('父$kind / 共同子名'), findsWidgets);
      expectSelected(tester, 'category-child-c$kind', true);
      await tap(tester, key('category-root-q$kind'));
      expectSelected(tester, 'category-root-q$kind', true);
      expect(key('category-child-c$kind'), findsNothing);
      expectSelected(tester, 'category-child-d$kind', false);
      await save(tester);
      final after = (await db.getAllBills()).single;
      final original = before.toJson()
        ..remove('categoryId')
        ..remove('updatedAt');
      final changed = after.toJson()
        ..remove('categoryId')
        ..remove('updatedAt');
      expect(changed, original);
      expect(after.categoryId, 'q$kind');
      expect(find.textContaining('另一父$kind'), findsOneWidget);
      await tap(tester, find.text('修改'));
      expectSelected(tester, 'category-root-q$kind', true);
      await disposePage(tester, db);
    });

    testWidgets('$kind OCR 分级选择、取消与采用不丢识别字段', (tester) async {
      final originalPicker = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = FakeImagePickerPlatform('/synthetic.jpg');
      mockMlKitTextRecognition([
        [
          '付款成功',
          '实付金额',
          '￥12.34',
          '交易时间',
          '2026-10-03 14:25:00',
          '付款方式',
          '微信',
          '餐饮测试商户',
        ],
      ]);
      addTearDown(() {
        ImagePickerPlatform.instance = originalPicker;
        clearMlKitMock();
      });
      final db = await seed();
      await openEditor(tester, db);
      if (kind == 1) await tap(tester, find.text('收入'));
      await tap(tester, find.byTooltip('图片识别记账'));
      await tap(tester, find.text('从相册选择'));
      expect(find.text('图片识别结果'), findsOneWidget);
      final fields = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '23.45');
      await tester.enterText(fields.at(1), 'OCR 保留备注');
      tester.testTextInput.hide();
      await tester.pump();
      await tap(tester, find.text('分类'));
      expect(key('category-root-c$kind'), findsNothing);
      await tap(
        tester,
        find.descendant(
          of: find.byType(BottomSheet).last,
          matching: key('category-root-p$kind'),
        ),
      );
      await tap(
        tester,
        find.descendant(
          of: find.byType(BottomSheet).last,
          matching: key('category-child-c$kind'),
        ),
      );
      await tap(tester, find.text('使用所选分类'));
      expect(find.textContaining('父$kind / 共同子名'), findsOneWidget);
      await tap(tester, find.text('分类'));
      await tap(
        tester,
        find.descendant(
          of: find.byType(BottomSheet).last,
          matching: key('category-root-q$kind'),
        ),
      );
      Navigator.of(tester.element(find.text('选择分类'))).pop(); // 取消二次选择，保留原二级。
      await settleProviders(tester);
      expect(find.textContaining('父$kind / 共同子名'), findsOneWidget);
      await tap(tester, find.text('采用并填入'));
      expect(find.text('父$kind-共同子名'), findsOneWidget);
      expectSelected(tester, 'category-child-c$kind', true);
      await save(tester);
      final bill = (await db.getAllBills()).single;
      expect(bill.type, kind);
      expect(bill.categoryId, 'c$kind');
      expect(bill.amount, 2345);
      expect(bill.accountId, 'acc_wechat');
      expect(bill.note, 'OCR 保留备注');
      expect(bill.dateMs, DateTime(2026, 10, 3, 14, 25).millisecondsSinceEpoch);
      await disposePage(tester, db);
    });
  }

  testWidgets('跨支出收入和转账重置分类，金额与备注不清空', (tester) async {
    final db = await seed();
    await openEditor(tester, db);
    await tap(tester, key('category-child-c0'));
    await tap(tester, find.text('5'));
    await tester.enterText(find.byType(TextField), '跨类型保留');
    tester.testTextInput.hide();
    await tester.pump();
    await tap(tester, find.text('收入'));
    expectSelected(tester, 'category-root-p1', true);
    await tap(tester, key('category-child-c1'));
    await tap(tester, find.text('转账'));
    expect(find.byType(CategoryPicker), findsNothing);
    await tap(tester, find.text('支出'));
    expectSelected(tester, 'category-root-p0', true);
    await save(tester);
    final bill = (await db.getAllBills()).single;
    expect(bill.categoryId, 'p0');
    expect(bill.type, 0);
    expect(bill.amount, 500);
    expect(bill.note, '跨类型保留');
    await disposePage(tester, db);
  });

  testWidgets('子级返回直接使用一级，重复点击当前类型保留选择', (tester) async {
    final db = await seed();
    await openEditor(tester, db);
    await tap(tester, key('category-child-c0'));
    await tap(tester, find.text('支出'));
    expectSelected(tester, 'category-child-c0', true);
    final categoryScroll = find
        .descendant(
          of: find.byType(CategoryPicker),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      key('category-root-p0'),
      -100,
      scrollable: categoryScroll,
    );
    await tester.pumpAndSettle();
    expect(find.text('父0-共同子名'), findsOneWidget);
    await tap(tester, key('category-root-p0'));
    expect(find.text('父0-共同子名'), findsNothing);
    expectSelected(tester, 'category-root-p0', true);
    await tester.scrollUntilVisible(
      key('category-child-c0'),
      100,
      scrollable: categoryScroll,
    );
    expectSelected(tester, 'category-child-c0', false);
    await tap(tester, find.text('5'));
    await save(tester);
    expect((await db.getAllBills()).single.categoryId, 'p0');
    await disposePage(tester, db);
  });

  testWidgets('明细展示完整路径，分类改名后列表与详情实时更新', (tester) async {
    final db = await seed();
    await db.upsertBill(
      id: 'list',
      type: 0,
      amount: 600,
      categoryId: 'c0',
      accountId: 'acc_cash',
      dateMs: DateTime.now().millisecondsSinceEpoch,
      note: '列表账单',
    );
    await pumpPage(tester, const BillsPage(), db: db);
    expect(find.textContaining('父0 / 共同子名'), findsOneWidget);
    await tap(tester, find.text('列表账单'));
    expect(
      find.descendant(
        of: find.byType(BillDetailPage),
        matching: find.textContaining('父0 / 共同子名'),
      ),
      findsOneWidget,
    );
    await tester.runAsync(
      () => db.upsertCategory(
        id: 'p0',
        name: '改名父',
        emoji: '🍜',
        kind: 0,
        sort: -30,
      ),
    );
    await settleProviders(tester);
    expect(
      find.descendant(
        of: find.byType(BillDetailPage),
        matching: find.textContaining('改名父 / 共同子名'),
      ),
      findsOneWidget,
    );
    Navigator.of(tester.element(find.text('账单详情'))).pop();
    await settleProviders(tester);
    expect(find.textContaining('改名父 / 共同子名'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('空分类安全显示，不提供可确认的虚构分类', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showCategoryPicker(
              context: context,
              categories: [],
              kind: 0,
              selectedId: null,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tap(tester, find.text('打开'));
    expect(key('category-selected-path'), findsNothing);
    expect(find.text('暂无分类，可先到分类管理新增'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '使用所选分类'))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏长名称可滚动，分类从列表移除后回退有效一级', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await seed();
    addTearDown(db.close);
    final rows = await db.getAllCategories();
    final long = rows
        .map(
          (c) => c.id == 'c0' ? c.copyWith(name: '一个很长很长很长很长的二级分类名称' * 10) : c,
        )
        .toList();
    await tester.pumpWidget(
      localizedApp(
        CategoryPicker(
          categories: long,
          kind: 0,
          selectedId: 'c0',
          onSelected: (_) {},
        ),
      ),
    );
    expect(find.textContaining('父0-一个很长'), findsOneWidget);
    expect(
      find.byTooltip('父0 / ${long.singleWhere((c) => c.id == 'c0').name}'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
    expect(
      categorySelection(rows.where((c) => c.id != 'c0').toList(), 0, 'c0'),
      'p0',
    );
    expect(categorySelection(rows, 1, 'c0'), 'p1');
    expect(categorySelection(rows, 2, 'c0'), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('二级面板位于选中一级所在行之后，后续一级行在面板下方', (tester) async {
    final categories = [
      for (var i = 0; i < 15; i++) fixtureCategory('root-$i', i),
      fixtureCategory('child-6', 0, parent: 'root-6'),
    ];
    await pumpPicker(tester, categories, 'root-0');
    await tap(tester, key('category-root-root-6'));
    final parent = tester.getRect(key('category-root-root-6'));
    final sameRowEnd = tester.getRect(key('category-root-root-9'));
    final panel = tester.getRect(key('category-child-panel-root-6'));
    final nextRow = tester.getRect(key('category-root-root-10'));
    expect(parent.top, sameRowEnd.top);
    expect(panel.top, greaterThanOrEqualTo(parent.bottom));
    expect(nextRow.top, greaterThanOrEqualTo(panel.bottom));
    expect(key('category-root-child-6'), findsNothing);
    expectSelected(tester, 'category-root-root-6', true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏编辑末尾一级的二级账单，初次加载自动回显可点击的父子格', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await seed();
    for (var i = 0; i < 20; i++) {
      await db.upsertCategory(
        id: 'before-tail-$i',
        name: '前排一级$i',
        emoji: '🍜',
        kind: 0,
        sort: 100 + i,
      );
    }
    await db.upsertCategory(
      id: 'tail-parent',
      name: '末尾一级',
      emoji: '🍜',
      kind: 0,
      sort: 1000,
    );
    await db.upsertCategory(
      id: 'tail-child',
      name: '末尾二级',
      emoji: '🍜',
      kind: 0,
      sort: 0,
      parentId: 'tail-parent',
    );
    await db.upsertBill(
      id: 'edit-tail-child',
      type: 0,
      amount: 1234,
      categoryId: 'tail-child',
      accountId: 'acc_cash',
      dateMs: DateTime(2026, 10, 10).millisecondsSinceEpoch,
      note: '末尾分类回显',
    );
    await openEditor(tester, db, bill: (await db.getAllBills()).single);
    expect(key('category-root-tail-parent').hitTestable(), findsOneWidget);
    expect(key('category-child-tail-child').hitTestable(), findsOneWidget);
    expect(find.text('末尾一级-末尾二级'), findsOneWidget);
    expectSelected(tester, 'category-root-tail-parent', true);
    expectSelected(tester, 'category-child-tail-child', true);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('没有二级的一级仅选中自身，不显示空面板和额外选择控件', (tester) async {
    final categories = [
      fixtureCategory('plain', 0),
      fixtureCategory('with-child', 1),
      fixtureCategory('child', 0, parent: 'with-child'),
    ];
    await pumpPicker(tester, categories, 'with-child');
    expect(key('category-child-panel-with-child'), findsOneWidget);
    await tap(tester, key('category-root-plain'));
    expect(key('category-child-panel-plain'), findsNothing);
    expect(key('category-child-panel-with-child'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('直接使用一级'), findsNothing);
    expect(key('category-selected-path'), findsNothing);
    expectSelected(tester, 'category-root-plain', true);
    expectSelected(tester, 'category-root-with-child', false);
  });

  testWidgets('更换一级替换二级面板与父格标签，子级完整路径仍可访问', (tester) async {
    final categories = [
      fixtureCategory('first', 0, name: '三餐'),
      fixtureCategory('second', 1, name: '交通'),
      fixtureCategory('dinner', 0, parent: 'first', name: '晚餐'),
      fixtureCategory('bus', 0, parent: 'second', name: '公交'),
    ];
    await pumpPicker(tester, categories, 'dinner');
    expect(find.text('三餐-晚餐'), findsOneWidget);
    expect(find.byTooltip('三餐 / 晚餐'), findsWidgets);
    expectSelected(tester, 'category-child-dinner', true);
    await tap(tester, key('category-root-second'));
    expect(key('category-child-panel-first'), findsNothing);
    expect(key('category-child-panel-second'), findsOneWidget);
    expect(find.text('三餐-晚餐'), findsNothing);
    expectSelected(tester, 'category-child-bus', false);
    await tap(tester, key('category-child-bus'));
    expect(find.text('交通-公交'), findsOneWidget);
    expect(find.byTooltip('交通 / 公交'), findsWidgets);
    expectSelected(tester, 'category-child-bus', true);
    await tap(tester, key('category-root-second'));
    expect(find.text('交通-公交'), findsNothing);
    expectSelected(tester, 'category-child-bus', false);
  });

  testWidgets('窄屏长名和大量二级可滚动选择末项，再滚动到后续一级', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final categories = [
      for (var i = 0; i < 15; i++)
        fixtureCategory('many-root-$i', i, name: '一级分类名称$i'),
      for (var i = 0; i < 30; i++)
        fixtureCategory(
          'many-$i',
          i,
          parent: 'many-root-1',
          name: '很长的二级分类名称$i',
        ),
    ];
    await pumpPicker(tester, categories, 'many-root-1');
    final scrollable = find
        .descendant(
          of: find.byType(CategoryPicker),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      key('category-child-many-29'),
      180,
      scrollable: scrollable,
    );
    await tap(tester, key('category-child-many-29'));
    expectSelected(tester, 'category-child-many-29', true);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      key('category-root-many-root-10'),
      180,
      scrollable: scrollable,
    );
    await tap(tester, key('category-root-many-root-10'));
    expect(key('category-child-panel-many-root-1'), findsNothing);
    expectSelected(tester, 'category-root-many-root-10', true);
    expect(tester.takeException(), isNull);
  });
}
