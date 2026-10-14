import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

Finder _key(String value) => find.byKey(ValueKey(value));
Finder _pad(String value) =>
    find.descendant(of: find.byType(NumberPad), matching: find.text(value));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; finder.evaluate().isEmpty && attempt < 8; attempt++) {
    final lists = find.byType(ListView);
    expect(lists, findsWidgets);
    await tester.drag(lists.last, const Offset(0, -180));
    await settleProviders(tester);
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await settleProviders(tester);
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
  await settleProviders(tester);
}

Future<TestAppDatabase> _seed() async {
  final db = TestAppDatabase();
  await db.getAllAccounts();
  for (final currency in [Currency.usd, Currency.jpy, Currency.eur]) {
    await db.upsertAccount(
      id: currency.code.toLowerCase(),
      name: '${currency.displayName}钱包',
      emoji: '💳',
      type: 0,
      initBalance: 0,
      includeNetWorth: true,
      sort: 100 + currency.index,
      currency: currency.code,
    );
  }
  return db;
}

Future<void> _open(
  WidgetTester tester,
  TestAppDatabase db, {
  Bill? bill,
  double textScale = 1,
}) async {
  await pumpPage(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (routeContext) => MediaQuery(
              data: MediaQuery.of(routeContext)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: EditBillPage(bill: bill),
            ),
          ),
        ),
        child: const Text('开始'),
      ),
    ),
    db: db,
  );
  await _tap(tester, find.text('开始'));
}

Future<void> _currency(WidgetTester tester, Currency currency) async {
  await _tap(tester, _key('entry-currency'));
  await _tap(
    tester,
    find.widgetWithText(ListTile, '${currency.displayName} ${currency.code}'),
  );
}

Future<void> _account(WidgetTester tester, String name) async {
  await _tap(tester, _key('entry-account'));
  await _tap(tester, find.widgetWithText(ListTile, name));
}

Future<void> _amount(WidgetTester tester, String value) async {
  for (final character in value.split('')) {
    await _tap(tester, _pad(character));
  }
}

Future<void> _actual(WidgetTester tester, String value) async {
  await _tap(tester, _key('entry-account-amount'));
  await tester.enterText(_key('account-amount-input'), value);
  tester.testTextInput.hide();
  await _tap(tester, find.text('确认'));
}

String _displayed(WidgetTester tester) =>
    tester.widget<Text>(_key('entry-displayed-amount')).data!;

void _expectInline(WidgetTester tester, Currency currency) {
  final entry = _key('entry-currency');
  expect(entry, findsOneWidget);
  expect(entry.hitTestable(), findsOneWidget);
  expect(
    find.descendant(of: entry, matching: find.text(currency.code)),
    findsOneWidget,
  );
  expect(find.byTooltip('选择币种'), findsOneWidget);
  final bounds = tester.getRect(entry);
  final amountBounds = tester.getRect(_key('entry-displayed-amount'));
  expect(bounds.width, greaterThanOrEqualTo(48));
  expect(bounds.height, greaterThanOrEqualTo(48));
  expect(bounds.left, greaterThanOrEqualTo(amountBounds.right - 0.01));
  expect((bounds.center.dy - amountBounds.center.dy).abs(), lessThan(2));
  for (final code in Currency.values) {
    expect(
      find.widgetWithText(ActionChip, '${code.displayName} ${code.code}'),
      findsNothing,
    );
  }
}

void main() {
  for (final sample in [
    (currency: Currency.usd, type: 0, input: '10.29', units: 1029),
    (currency: Currency.jpy, type: 1, input: '1234', units: 1234),
  ]) {
    testWidgets('点金额右侧切换${sample.currency.code}并按原币精度保存收支', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      if (sample.type == 1) await _tap(tester, find.text('收入'));
      _expectInline(tester, Currency.cny);
      await _currency(tester, sample.currency);
      _expectInline(tester, sample.currency);
      await _account(tester, '${sample.currency.displayName}钱包');
      await _amount(tester, sample.input);
      expect(_displayed(tester), sample.input);
      await _tap(tester, _pad('保存'));

      final saved = (await db.getAllBills()).single;
      expect(saved.type, sample.type);
      expect(saved.currency, sample.currency.code);
      expect(saved.accountId, sample.currency.code.toLowerCase());
      expect(saved.amount, sample.units);
      expect(saved.accountAmount, sample.units);
      expect(find.byType(EditBillPage), findsNothing);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('关闭金额旁币种面板保留金额备注二级分类日期和账户', (tester) async {
    final db = await _seed();
    await db.upsertCategory(
      id: 'inline-dinner',
      parentId: 'cat_food',
      name: '晚餐',
      emoji: '🍚',
      kind: 0,
      sort: 0,
    );
    await db.upsertBill(
      id: 'inline-original',
      type: 0,
      amount: 1029,
      categoryId: 'inline-dinner',
      accountId: 'acc_cash',
      dateMs: DateTime(2026, 10, 3, 14, 25, 7, 123).millisecondsSinceEpoch,
      createdAt: 77,
      note: '保留这笔晚餐备注',
    );
    final original = (await db.getAllBills()).single;
    await _open(tester, db, bill: original);
    _expectInline(tester, Currency.cny);
    await _tap(tester, _key('entry-currency'));
    expect(find.text('选择币种'), findsOneWidget);
    Navigator.of(tester.element(find.text('选择币种'))).pop();
    await settleProviders(tester);
    expect(_displayed(tester), '10.29');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      original.note,
    );
    await _tap(tester, _pad('保存'));

    final saved = (await db.getAllBills()).single;
    expect(
      saved.toJson()..remove('updatedAt'),
      original.toJson()..remove('updatedAt'),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('金额旁切币不换算数字，并使先前跨币实扣重新待确认', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _amount(tester, '10.29');
    await _currency(tester, Currency.usd);
    expect(_displayed(tester), '10.29');
    await _tap(tester, _pad('保存'));
    expect(await db.getAllBills(), isEmpty);
    expect(find.text('请确认账户实际收付款额'), findsOneWidget);
    await _actual(tester, '72.29');
    await _currency(tester, Currency.eur);
    expect(_displayed(tester), '10.29');
    expect(find.widgetWithText(ActionChip, '实扣 CNY 待确认'), findsOneWidget);
    await _tap(tester, _pad('保存'));
    expect(await db.getAllBills(), isEmpty);
    await _actual(tester, '79.20');
    await _tap(tester, _pad('保存'));

    final saved = (await db.getAllBills()).single;
    expect(saved.currency, 'EUR');
    expect(saved.accountId, 'acc_cash');
    expect(saved.amount, 1029);
    expect(saved.accountAmount, 7920);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('编辑回显金额右侧USD，切为EUR保存并保留原始非金额字段', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'inline-usd-original',
      type: 0,
      currency: 'USD',
      amount: 1029,
      accountAmount: 1029,
      categoryId: 'cat_food',
      accountId: 'usd',
      dateMs: DateTime(2026, 10, 3, 14, 25, 7, 123).millisecondsSinceEpoch,
      createdAt: 77,
      note: '外币原账备注',
    );
    final original = (await db.getAllBills()).single;
    await _open(tester, db, bill: original);
    expect(_displayed(tester), '10.29');
    _expectInline(tester, Currency.usd);
    await _currency(tester, Currency.eur);
    _expectInline(tester, Currency.eur);
    await _actual(tester, '11.50');
    await _tap(tester, _pad('保存'));

    final saved = (await db.getAllBills()).single;
    expect(saved.currency, 'EUR');
    expect(saved.amount, 1029);
    expect(saved.accountAmount, 1150);
    expect(
      saved.toJson()
        ..remove('updatedAt')
        ..remove('currency')
        ..remove('accountAmount'),
      original.toJson()
        ..remove('updatedAt')
        ..remove('currency')
        ..remove('accountAmount'),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final width in [320.0, 360.0]) {
    testWidgets('${width.toInt()}宽大字体金额旁入口可操作，数字键盘和保存可见', (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await _seed();
      await _open(tester, db, textScale: 1.5);
      await _amount(tester, '1234567890.29');
      _expectInline(tester, Currency.cny);
      final currencyBounds = tester.getRect(_key('entry-currency'));
      final amountBounds = tester.getRect(_key('entry-displayed-amount'));
      expect(currencyBounds.left, greaterThanOrEqualTo(0));
      expect(currencyBounds.right, lessThanOrEqualTo(width));
      expect(amountBounds.left, greaterThanOrEqualTo(0));
      expect(amountBounds.right, lessThanOrEqualTo(currencyBounds.left));
      final semantics = tester.ensureSemantics();
      try {
        await tester.pump();
        final node = tester.getSemantics(_key('entry-currency'));
        final semanticsData = node.getSemanticsData();
        expect(semanticsData.hasAction(SemanticsAction.tap), isTrue);
        expect(semanticsData.label, contains('CNY'));
        expect(
          '${semanticsData.label} ${semanticsData.tooltip}',
          contains('选择币种'),
        );
      } finally {
        semantics.dispose();
      }
      expect(_pad('7').hitTestable(), findsOneWidget);
      expect(_pad('保存').hitTestable(), findsOneWidget);

      await _currency(tester, Currency.usd);
      _expectInline(tester, Currency.usd);
      expect(_displayed(tester), '1234567890.29');
      await _account(tester, '美元钱包');
      expect(_pad('保存').hitTestable(), findsOneWidget);
      await _tap(tester, _pad('保存'));
      final saved = (await db.getAllBills()).single;
      expect(saved.currency, 'USD');
      expect(saved.amount, 123456789029);
      expect(saved.accountAmount, 123456789029);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('转账金额旁币种只读随来源更新，没有额外可切币入口', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _tap(tester, find.text('转账'));
    expect(_key('entry-currency'), findsNothing);
    expect(find.byTooltip('选择币种'), findsNothing);
    await _account(tester, '美元钱包');
    expect(_key('entry-currency'), findsNothing);
    expect(find.byTooltip('选择币种'), findsNothing);
    expect(find.text(' USD'), findsOneWidget);
    await _amount(tester, '10.29');
    await _tap(tester, _key('transfer-to-account'));
    await _tap(tester, find.widgetWithText(ListTile, '日元钱包'));
    await _tap(tester, _key('transfer-received-amount'));
    await tester.enterText(_key('account-amount-input'), '1500');
    tester.testTextInput.hide();
    await _tap(tester, find.text('确认'));
    await _tap(tester, _pad('保存'));

    final saved = (await db.getAllBills()).single;
    expect(saved.type, 2);
    expect(saved.currency, 'USD');
    expect(saved.accountId, 'usd');
    expect(saved.toAccountId, 'jpy');
    expect(saved.amount, 1029);
    expect(saved.accountAmount, 1029);
    expect(saved.toAccountAmount, 1500);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
