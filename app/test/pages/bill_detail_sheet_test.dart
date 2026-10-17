import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/account_info_page.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/providers.dart';

import '../helpers/test_support.dart';

Finder get _detail => find.byType(BillDetailPage);
Finder _detailText(String text) =>
    find.descendant(of: _detail, matching: find.text(text));
Finder get _detailScroll => find.byKey(const ValueKey('bill-detail-scroll'));

Future<Bill> _seedBill(
  AppDatabase db, {
  String id = 'sheet-bill',
  String note = '弹层测试账单',
  int amount = 1234,
  int type = 0,
  DateTime? date,
}) async {
  await db.getAllAccounts();
  final now = DateTime.now();
  await db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    categoryId: type == 1 ? 'inc_salary' : 'cat_food',
    accountId: 'acc_cash',
    dateMs: (date ?? DateTime(now.year, now.month, 3, 14, 25))
        .millisecondsSinceEpoch,
    note: note,
  );
  return (await db.getAllBills()).singleWhere((bill) => bill.id == id);
}

Widget _host(Bill bill) => Builder(
  builder: (context) => Center(
    child: TextButton(
      onPressed: () => showBillDetailSheet(context: context, bill: bill),
      child: const Text('打开测试详情'),
    ),
  ),
);

Future<void> _openFromList(WidgetTester tester, String note) async {
  await tester.tap(find.text(note));
  await settleProviders(tester);
  expect(_detail, findsOneWidget);
  expect(find.byType(BottomSheet), findsOneWidget);
}

double _scrollOffset(WidgetTester tester, Finder scrollParent) => tester
    .state<ScrollableState>(
      find
          .descendant(of: scrollParent, matching: find.byType(Scrollable))
          .first,
    )
    .position
    .pixels;

Future<void> _saveEditor(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('保存'));
  });
  // 数据库保存和路由动画均有界等待，不能仅断言点击过保存。
  for (
    var i = 0;
    i < 50 && find.byType(EditBillPage).evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(EditBillPage), findsNothing);
  await settleProviders(tester);
}

void main() {
  testWidgets('明细真实入口打开只读底部窗口，短详情按内容收缩且保留背后月份', (tester) async {
    final db = TestAppDatabase();
    await _seedBill(db);
    await pumpPage(tester, const BillsPage(), db: db);
    final month = DateTime.now();
    await _openFromList(tester, '弹层测试账单');

    final sheetRect = tester.getRect(find.byType(BottomSheet));
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(sheetRect.bottom, closeTo(screenHeight, 0.1));
    expect(sheetRect.top, greaterThan(screenHeight * 0.15));
    expect(sheetRect.height, lessThan(screenHeight * 0.8));
    expect(_detailText('账单详情'), findsOneWidget);
    expect(_detailText('-¥ 12.34'), findsOneWidget);
    expect(_detailText('弹层测试账单'), findsOneWidget);
    expect(find.text('${month.year}年${month.month}月'), findsOneWidget);
    expect(
      find.descendant(of: _detail, matching: find.byType(Scaffold)),
      findsNothing,
    );
    expect(
      find.descendant(of: _detail, matching: find.byType(AppBar)),
      findsNothing,
    );
    expect(find.byType(EditBillPage), findsNothing);
    expect(_detailText('修改').hitTestable(), findsOneWidget);
    expect(find.byTooltip('关闭详情').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('账户动账入口复用底部详情，关闭后仍在账户信息', (tester) async {
    final db = TestAppDatabase();
    await _seedBill(db, type: 1, note: '账户收入详情');
    final account = (await db.getAllAccounts()).singleWhere(
      (account) => account.id == 'acc_cash',
    );
    await pumpPage(tester, AccountInfoPage(account: account), db: db);
    await _openFromList(tester, '账户收入详情');
    expect(_detailText('+¥ 12.34'), findsOneWidget);
    expect(_detailText('收入'), findsOneWidget);
    expect(find.byType(AccountInfoPage), findsOneWidget);

    await tester.tap(find.byTooltip('关闭详情'));
    await settleProviders(tester);
    expect(_detail, findsNothing);
    expect(find.byType(AccountInfoPage), findsOneWidget);
    expect(find.text('账户余额'), findsOneWidget);
    expect(find.text('账户收入详情'), findsOneWidget);
    await disposePage(tester, db);
  });

  for (final closeMethod in ['关闭按钮', '遮罩', '系统返回', '向下拖动']) {
    testWidgets('$closeMethod关闭详情后只关闭弹层，不改变账单或列表', (tester) async {
      final db = TestAppDatabase();
      final before = await _seedBill(db);
      await pumpPage(tester, const BillsPage(), db: db);
      await _openFromList(tester, before.note);

      switch (closeMethod) {
        case '关闭按钮':
          await tester.tap(find.byTooltip('关闭详情'));
        case '遮罩':
          final sheet = tester.getRect(find.byType(BottomSheet));
          expect(sheet.top, greaterThan(20));
          await tester.tapAt(Offset(sheet.center.dx, sheet.top / 2));
        case '系统返回':
          await tester.binding.handlePopRoute();
        case '向下拖动':
          await tester.drag(_detailText('账单详情'), const Offset(0, 500));
      }
      await settleProviders(tester);

      expect(_detail, findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(BillsPage), findsOneWidget);
      expect(find.text(before.note), findsOneWidget);
      expect((await db.getAllBills()).single, before);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final keyboardHeight in [0.0, 180.0]) {
    testWidgets('320x480大字体长备注可滚动读到底，键盘高度$keyboardHeight时操作仍可见', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetViewInsets);
      final db = TestAppDatabase();
      final note =
          '${List.generate(18, (i) => '长备注第${i + 1}行，保留完整文字与换行。').join('\n')}\n备注最后一行';
      final bill = await _seedBill(db, note: note);
      await pumpPage(tester, _host(bill), db: db);
      await tester.tap(find.text('打开测试详情'));
      await settleProviders(tester);

      // BottomSheet 的 Material 还包含键盘避让 Padding；验证真实内容边界。
      final sheet = tester.getRect(
        find.byKey(const ValueKey('bill-detail-sheet')),
      );
      expect(sheet.top, greaterThanOrEqualTo(0));
      expect(sheet.bottom, lessThanOrEqualTo(480 - keyboardHeight + 0.1));
      expect(
        sheet.height,
        lessThanOrEqualTo((480 - keyboardHeight) * .85 + 0.1),
      );
      final state = tester.state<ScrollableState>(
        find
            .descendant(of: _detailScroll, matching: find.byType(Scrollable))
            .first,
      );
      expect(state.position.maxScrollExtent, greaterThan(0));
      for (var i = 0; i < 30 && state.position.extentAfter > 0.5; i++) {
        await tester.drag(_detailScroll, const Offset(0, -350));
        await settleProviders(tester);
      }
      expect(state.position.pixels, greaterThan(0));
      expect(state.position.extentAfter, lessThan(0.5));
      final noteRect = tester.getRect(_detailText(note));
      final viewport = tester.getRect(_detailScroll);
      // 验证末行进入视口，不能只用 find.text 证明被裁切的文字已构建。
      expect(noteRect.bottom, lessThanOrEqualTo(viewport.bottom + 1));
      expect(noteRect.bottom, greaterThan(viewport.top));
      expect(_detailText('账单详情').hitTestable(), findsOneWidget);
      expect(_detailText('修改').hitTestable(), findsOneWidget);
      expect(find.byTooltip('关闭详情').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('弹层修改保存回到原窗口，连续编辑读取最新金额备注且列表同步', (tester) async {
    final db = TestAppDatabase();
    await _seedBill(db, note: '弹层编辑前');
    await pumpPage(tester, const BillsPage(), db: db);
    await _openFromList(tester, '弹层编辑前');

    await tester.tap(_detailText('修改'));
    await settleProviders(tester);
    expect(find.byType(EditBillPage), findsOneWidget);
    await tester.longPress(find.text('⌫'));
    await tester.tap(find.text('2'));
    await tester.tap(find.text('0'));
    await tester.enterText(find.byType(TextField), '弹层第一次保存');
    tester.testTextInput.hide();
    await _saveEditor(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(_detailText('-¥ 20.00'), findsOneWidget);
    expect(_detailText('弹层第一次保存'), findsOneWidget);
    expect(find.text('弹层编辑前'), findsNothing);

    await tester.tap(_detailText('修改'));
    await settleProviders(tester);
    final noteField = tester.widget<TextField>(find.byType(TextField));
    expect(noteField.controller!.text, '弹层第一次保存');
    await tester.enterText(find.byType(TextField), '弹层第二次保存');
    tester.testTextInput.hide();
    await _saveEditor(tester);
    expect(_detailText('-¥ 20.00'), findsOneWidget);
    expect(_detailText('弹层第二次保存'), findsOneWidget);
    final saved = (await db.getAllBills()).single;
    expect(saved.amount, 2000);
    expect(saved.note, '弹层第二次保存');
    expect(saved.accountId, 'acc_cash');
    expect(saved.categoryId, 'cat_food');

    await tester.tap(find.byTooltip('关闭详情'));
    await settleProviders(tester);
    expect(find.text('弹层第二次保存'), findsOneWidget);
    expect(find.text('弹层第一次保存'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('窗口打开期间账单软删除，展示状态并撤掉修改入口且仍能关闭', (tester) async {
    final db = TestAppDatabase();
    final bill = await _seedBill(db);
    await pumpPage(tester, const BillsPage(), db: db);
    await _openFromList(tester, bill.note);
    await db.softDeleteBill(bill.id);
    await settleProviders(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(_detailText('账单已删除或不存在'), findsOneWidget);
    expect(_detailText('修改'), findsNothing);
    expect(_detailText('-¥ 12.34'), findsNothing);
    expect(
      tester.getSize(find.byType(BottomSheet)).height,
      lessThan(
        tester.view.physicalSize.height / tester.view.devicePixelRatio * .5,
      ),
    );
    expect(await db.getAllBills(), isEmpty);
    await tester.tap(find.byTooltip('关闭详情'));
    await settleProviders(tester);
    expect(_detail, findsNothing);
    expect(find.text('本月还没有账单'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('真实长列表滚动后查看关闭详情，选中月份与原列表偏移均保留', (tester) async {
    final db = TestAppDatabase();
    for (var day = 1; day <= 28; day++) {
      await _seedBill(
        db,
        id: 'position-$day',
        note: '位置第$day日',
        date: DateTime(2024, 12, day, 12),
      );
    }
    await pumpPage(tester, const BillsPage(), db: db);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BillsPage)),
    );
    container
        .read(selectedMonthProvider.notifier)
        .selectMonth(DateTime(2024, 12));
    await settleProviders(tester);
    final list = find.byKey(const ValueKey('bills-2024-12'));
    await tester.drag(list, const Offset(0, -700));
    await settleProviders(tester);
    final offsetBefore = _scrollOffset(tester, list);
    expect(offsetBefore, greaterThan(0));
    final target = find
        .textContaining(RegExp(r'^位置第\d+日$'))
        .hitTestable()
        .first;
    final note = tester.widget<Text>(target).data!;
    await tester.tap(target);
    await settleProviders(tester);
    expect(_detailText(note), findsOneWidget);
    expect(container.read(selectedMonthProvider), DateTime(2024, 12));
    await tester.tap(find.byTooltip('关闭详情'));
    await settleProviders(tester);

    expect(_detail, findsNothing);
    expect(container.read(selectedMonthProvider), DateTime(2024, 12));
    expect(_scrollOffset(tester, list), closeTo(offsetBefore, 0.01));
    expect(find.text(note).hitTestable(), findsOneWidget);
    expect((await db.getAllBills()).length, 28);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
