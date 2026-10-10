import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/pages/home_shell.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';

import '../helpers/test_support.dart';

Finder _inEditor(Finder matching) =>
    find.descendant(of: find.byType(EditBillPage), matching: matching);
Finder _inDetail(String text) =>
    find.descendant(of: find.byType(BillDetailPage), matching: find.text(text));

Future<void> _saveEditor(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(_inEditor(find.text('保存')));
  });
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
  for (final example in [
    (input: '123', cents: 12300, type: 0, display: '-¥ 123.00'),
    (input: '0.29', cents: 29, type: 1, display: '+¥ 0.29'),
  ]) {
    testWidgets('主页记账真实键盘输入 ${example.input} 保存精确 CNY 金额', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = TestAppDatabase();
      await pumpPage(tester, const HomeShell(), db: db);
      await tester.tap(find.byIcon(Icons.add));
      await settleProviders(tester);
      if (example.type == 1) {
        await tester.tap(_inEditor(find.text('收入')));
        await settleProviders(tester);
      }
      for (final key in example.input.split('')) {
        await tester.tap(
          find.descendant(of: find.byType(NumberPad), matching: find.text(key)),
        );
        await tester.pump();
      }
      expect(_inEditor(find.text(example.input)).hitTestable(), findsOneWidget);
      expect(
        tester.getRect(_inEditor(find.text(' CNY'))).right,
        closeTo(348, 1),
      );
      final noteRect = tester.getRect(_inEditor(find.byType(TextField)));
      final inputRect = tester.getRect(_inEditor(find.text(example.input)));
      expect(noteRect.right + 8, closeTo(inputRect.left, 1));
      expect(noteRect.width, greaterThan(120));
      expect(
        inputRect.right + 4,
        closeTo(tester.getRect(_inEditor(find.text(' CNY'))).left, 1),
      );
      expect(tester.takeException(), isNull);
      final note = '精确输入 ${example.input}';
      await tester.enterText(_inEditor(find.byType(TextField)), note);
      tester.testTextInput.hide();
      await _saveEditor(tester);

      final saved = (await db.getAllBills()).single;
      expect(saved.amount, example.cents);
      expect(saved.type, example.type);
      expect(saved.note, note);
      expect(saved.accountId, 'acc_cash');
      expect(saved.categoryId, example.type == 1 ? 'inc_salary' : 'cat_food');
      await tester.tap(find.text(note));
      await settleProviders(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(_inDetail(example.display), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('超出 double 精确整数范围的账单只改备注，保存及再次回填不损失一分', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = TestAppDatabase();
    await db.getAllAccounts();
    final now = DateTime.now();
    final date = DateTime(now.year, now.month, 2, 14, 25, 13, 321);
    const amount = 9007199254740993;
    await db.upsertBill(
      id: 'precision-large-bill',
      type: 0,
      amount: amount,
      categoryId: 'cat_shopping',
      accountId: 'acc_bank',
      dateMs: date.millisecondsSinceEpoch,
      note: '大额精确账单',
    );
    final before = (await db.getAllBills()).single;
    await pumpPage(tester, const BillsPage(), db: db);
    await tester.tap(find.text(before.note));
    await settleProviders(tester);
    const detailAmount = '-¥ 90,071,992,547,409.93';
    const plainAmount = '90071992547409.93';
    expect(_inDetail(detailAmount), findsOneWidget);
    await tester.tap(_inDetail('修改'));
    await settleProviders(tester);
    final inputAmount = _inEditor(find.text(plainAmount));
    expect(inputAmount.hitTestable(), findsOneWidget);
    final amountRect = tester.getRect(inputAmount);
    expect(amountRect.left, greaterThanOrEqualTo(0));
    expect(amountRect.right, lessThanOrEqualTo(360));
    expect(amountRect.top, greaterThanOrEqualTo(0));
    expect(amountRect.bottom, lessThanOrEqualTo(640));
    expect(tester.takeException(), isNull);
    await tester.enterText(_inEditor(find.byType(TextField)), '只修改备注');
    tester.testTextInput.hide();
    await _saveEditor(tester);

    final saved = (await db.getAllBills()).single;
    expect(saved.id, before.id);
    expect(saved.amount, amount);
    expect(saved.type, before.type);
    expect(saved.accountId, before.accountId);
    expect(saved.toAccountId, before.toAccountId);
    expect(saved.categoryId, before.categoryId);
    expect(saved.dateMs, before.dateMs);
    expect(saved.createdAt, before.createdAt);
    expect(saved.note, '只修改备注');
    expect(_inDetail(detailAmount), findsOneWidget);
    expect(_inDetail('只修改备注'), findsOneWidget);
    await tester.tap(_inDetail('修改'));
    await settleProviders(tester);
    expect(_inEditor(find.text(plainAmount)).hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<TextField>(_inEditor(find.byType(TextField)))
          .controller!
          .text,
      '只修改备注',
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
