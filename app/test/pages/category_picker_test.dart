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
        expect(find.text('父$kind 的二级分类（可选）'), findsOneWidget);
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
      expect(find.text('已选：父$kind / 共同子名'), findsOneWidget);
      expect(
        tester.widget<ChoiceChip>(key('category-child-c$kind')).selected,
        isTrue,
      );
      await tap(tester, key('category-root-q$kind'));
      expect(find.text('已选：另一父$kind'), findsOneWidget);
      expect(key('category-child-c$kind'), findsNothing);
      expect(
        tester.widget<ChoiceChip>(key('category-direct-q$kind')).selected,
        isTrue,
      );
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
      expect(find.text('已选：另一父$kind'), findsOneWidget);
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
      expect(find.text('已选：父$kind / 共同子名'), findsOneWidget);
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
    expect(find.text('已选：父1'), findsOneWidget);
    await tap(tester, key('category-child-c1'));
    await tap(tester, find.text('转账'));
    expect(find.byType(CategoryPicker), findsNothing);
    await tap(tester, find.text('支出'));
    expect(find.text('已选：父0'), findsOneWidget);
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
    expect(find.text('已选：父0 / 共同子名'), findsOneWidget);
    await tap(tester, key('category-direct-p0'));
    expect(find.text('已选：父0'), findsOneWidget);
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
    expect(find.textContaining('父0 / 共同子名'), findsOneWidget);
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
    expect(find.textContaining('改名父 / 共同子名'), findsOneWidget);
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
    expect(find.text('已选：未分类'), findsOneWidget);
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
    expect(find.textContaining('父0 / 一个很长'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      categorySelection(rows.where((c) => c.id != 'c0').toList(), 0, 'c0'),
      'p0',
    );
    expect(categorySelection(rows, 1, 'c0'), 'p1');
    expect(categorySelection(rows, 2, 'c0'), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
