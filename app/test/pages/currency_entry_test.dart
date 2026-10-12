import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

Finder _key(String name) => find.byKey(ValueKey(name));
Finder _pad(String text) =>
    find.descendant(of: find.byType(NumberPad), matching: find.text(text));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  // 列表按需构建，ensureVisible 只能处理已构建的项。
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

Future<TestAppDatabase> _seed({bool paired = false}) async {
  final db = TestAppDatabase();
  await db.getAllAccounts();
  for (final currency in Currency.values.where((c) => c != Currency.cny)) {
    await db.upsertAccount(
      id: currency.code.toLowerCase(),
      name: '${currency.displayName}钱包',
      emoji: '💳',
      type: 0,
      initBalance: 0,
      includeNetWorth: true,
      sort: -100 + currency.index,
      currency: currency.code,
    );
  }
  if (paired) {
    for (final entry in {
      'myUid': 'me',
      'myName': '我',
      'partnerUid': 'partner',
      'partnerName': '伙伴',
      'pairSecret': 'secret',
    }.entries) {
      await db.setMeta(entry.key, entry.value);
    }
    await db.upsertAccount(
      id: kAaCreditAccountId,
      name: 'AA挂账',
      emoji: '🤝',
      type: 4,
      initBalance: 0,
      includeNetWorth: false,
      sort: 99,
    );
  }
  return db;
}

Future<void> _open(
  WidgetTester tester,
  TestAppDatabase db, {
  Bill? bill,
}) async {
  await pumpPage(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => EditBillPage(bill: bill)),
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

Future<void> _amount(WidgetTester tester, String text) async {
  for (final character in text.split('')) {
    await _tap(tester, _pad(character == '-' ? '−' : character));
  }
}

Future<void> _actual(WidgetTester tester, String text) async {
  await _tap(tester, _key('entry-account-amount'));
  await tester.enterText(_key('account-amount-input'), text);
  tester.testTextInput.hide();
  await _tap(tester, find.text('确认'));
}

Future<void> _note(WidgetTester tester, String note) async {
  await tester.enterText(find.byType(TextField), note);
  tester.testTextInput.hide();
  await tester.pump();
}

Future<void> _save(WidgetTester tester) => _tap(tester, _pad('保存'));

void _expectSaved(
  Bill bill, {
  required int type,
  required String currency,
  required String account,
  required int amount,
  required int actual,
}) {
  expect(bill.type, type);
  expect(bill.currency, currency);
  expect(bill.accountId, account);
  expect(bill.amount, amount);
  expect(bill.accountAmount, actual);
  expect(bill.toAccountId, isNull);
  expect(bill.toAccountAmount, isNull);
  expect(bill.aaGroupId, isNull);
  expect(bill.settlementId, isNull);
}

void main() {
  for (final type in [0, 1]) {
    testWidgets('USD ${type == 0 ? '支出' : '收入'}可选择美元账户并保存同币双金额', (
      tester,
    ) async {
      final db = await _seed();
      await _open(tester, db);
      if (type == 1) await _tap(tester, find.text('收入'));
      await _currency(tester, Currency.usd);
      await _account(tester, '美元钱包');
      expect(_key('entry-account-amount'), findsNothing);
      await _amount(tester, '10.29');
      await _save(tester);

      _expectSaved(
        (await db.getAllBills()).single,
        type: type,
        currency: 'USD',
        account: 'usd',
        amount: 1029,
        actual: 1029,
      );
      expect(find.byType(EditBillPage), findsNothing);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final type in [0, 1]) {
    testWidgets('只有外币钱包时${type == 0 ? '支出' : '收入'}可显式选择并按实际美元金额保存', (
      tester,
    ) async {
      final db = await _seed();
      for (final account in await db.getAllAccounts()) {
        if (account.id != 'usd') await db.deleteAccount(account.id);
      }
      await _open(tester, db);
      if (type == 1) await _tap(tester, find.text('收入'));
      await _account(tester, '美元钱包');
      await _amount(tester, '72');
      await _actual(tester, '10');
      await _save(tester);
      _expectSaved(
        (await db.getAllBills()).single,
        type: type,
        currency: 'CNY',
        account: 'usd',
        amount: 7200,
        actual: 1000,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final currency in [Currency.hkd, Currency.eur, Currency.gbp]) {
    testWidgets('${currency.code}收入使用本币精度且不写为人民币', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      await _tap(tester, find.text('收入'));
      await _currency(tester, currency);
      await _account(tester, '${currency.displayName}钱包');
      await _amount(tester, '0.29');
      await _save(tester);

      _expectSaved(
        (await db.getAllBills()).single,
        type: 1,
        currency: currency.code,
        account: currency.code.toLowerCase(),
        amount: 29,
        actual: 29,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final type in [0, 1]) {
    testWidgets('USD10 ${type == 0 ? '支出实扣' : '收入实收'}CNY72分别保留交易与账户金额', (
      tester,
    ) async {
      final db = await _seed();
      await _open(tester, db);
      if (type == 1) await _tap(tester, find.text('收入'));
      await _currency(tester, Currency.usd);
      await _account(tester, '现金');
      await _amount(tester, '10');
      await _tap(tester, _key('entry-account-amount'));
      expect(find.text(type == 0 ? '账户实际扣款' : '账户实际入账'), findsOneWidget);
      await tester.enterText(_key('account-amount-input'), '72');
      tester.testTextInput.hide();
      await _tap(tester, find.text('确认'));
      await _save(tester);

      _expectSaved(
        (await db.getAllBills()).single,
        type: type,
        currency: 'USD',
        account: 'acc_cash',
        amount: 1000,
        actual: 7200,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });

    testWidgets('跨币${type == 0 ? '支出' : '收入'}未确认账户实际金额时不能写入', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      if (type == 1) await _tap(tester, find.text('收入'));
      await _currency(tester, Currency.usd);
      await _account(tester, '现金');
      await _amount(tester, '10');
      await _save(tester);

      expect(await db.getAllBills(), isEmpty);
      expect(find.byType(EditBillPage), findsOneWidget);
      expect(_key('entry-account-amount'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('人民币交易可选美元账户，实际美元扣款按USD精度保存', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, '美元钱包');
    await _amount(tester, '72');
    await _actual(tester, '10.29');
    await _save(tester);

    _expectSaved(
      (await db.getAllBills()).single,
      type: 0,
      currency: 'CNY',
      account: 'usd',
      amount: 7200,
      actual: 1029,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('账户实扣拒绝负数、零、指数及过精度，不四舍五入', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _currency(tester, Currency.usd);
    await _account(tester, '现金');
    await _amount(tester, '10');
    await _tap(tester, _key('entry-account-amount'));
    for (final invalid in ['-1', '0', '1e3', '72.001']) {
      await tester.enterText(_key('account-amount-input'), invalid);
      tester.testTextInput.hide();
      await _tap(tester, find.text('确认'));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(await db.getAllBills(), isEmpty);
    }
    await tester.enterText(_key('account-amount-input'), '72.29');
    tester.testTextInput.hide();
    await _tap(tester, find.text('确认'));
    await _save(tester);
    expect((await db.getAllBills()).single.accountAmount, 7229);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('JPY交易使用整数，数字键盘的小数点不会产生日元小数', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _currency(tester, Currency.jpy);
    await _account(tester, '日元钱包');
    await _amount(tester, '123');
    await _tap(tester, _pad('.'));
    expect(find.text('123.'), findsNothing);
    await _save(tester);

    _expectSaved(
      (await db.getAllBills()).single,
      type: 0,
      currency: 'JPY',
      account: 'jpy',
      amount: 123,
      actual: 123,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('USD交易的JPY账户实际入账拒绝小数并按整数写入', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _tap(tester, find.text('收入'));
    await _currency(tester, Currency.usd);
    await _account(tester, '日元钱包');
    await _amount(tester, '10');
    await _tap(tester, _key('entry-account-amount'));
    await tester.enterText(_key('account-amount-input'), '1500.0');
    tester.testTextInput.hide();
    await _tap(tester, find.text('确认'));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(_key('account-amount-input'), '1500');
    tester.testTextInput.hide();
    await _tap(tester, find.text('确认'));
    await _save(tester);

    _expectSaved(
      (await db.getAllBills()).single,
      type: 1,
      currency: 'USD',
      account: 'jpy',
      amount: 1000,
      actual: 1500,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('切JPY保留已有小数输入并拒绝保存，切回USD不损失数字', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _currency(tester, Currency.usd);
    await _account(tester, '美元钱包');
    await _amount(tester, '10.29');
    await _currency(tester, Currency.jpy);
    await _account(tester, '日元钱包');
    expect(find.text('10.29'), findsOneWidget);
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    await _currency(tester, Currency.usd);
    await _account(tester, '美元钱包');
    await _save(tester);
    expect((await db.getAllBills()).single.amount, 1029);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('切换币种不清空已有金额、备注、日期或二级分类', (tester) async {
    final db = await _seed();
    await db.upsertCategory(
      id: 'food-child',
      name: '晚餐',
      emoji: '🍚',
      kind: 0,
      sort: 0,
      parentId: 'cat_food',
    );
    await db.upsertBill(
      id: 'original',
      type: 0,
      amount: 1029,
      categoryId: 'food-child',
      accountId: 'acc_cash',
      dateMs: 1791027900321,
      createdAt: 77,
      note: '保留全部输入',
    );
    final before = (await db.getAllBills()).single;
    await _open(tester, db, bill: before);
    await _currency(tester, Currency.usd);
    await _currency(tester, Currency.cny);
    await _account(tester, '现金');
    await _save(tester);

    final after = (await db.getAllBills()).single;
    expect(
      after.toJson()..remove('updatedAt'),
      before.toJson()..remove('updatedAt'),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('已有USD跨币账单只改备注保留双金额、ID、日期与创建时间', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'original',
      type: 0,
      amount: 1029,
      currency: 'USD',
      accountAmount: 7229,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: 1791027900321,
      createdAt: 77,
      note: '原备注',
    );
    final before = (await db.getAllBills()).single;
    await _open(tester, db, bill: before);
    expect(find.byType(NumberPad), findsOneWidget);
    await _note(tester, '新备注');
    await _save(tester);

    final after = (await db.getAllBills()).single;
    expect(after.note, '新备注');
    expect(
      after.toJson()
        ..remove('updatedAt')
        ..remove('note'),
      before.toJson()
        ..remove('updatedAt')
        ..remove('note'),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('修改已有跨币交易金额后须重新确认实扣，失败不改历史账单', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'original',
      type: 0,
      amount: 1000,
      currency: 'USD',
      accountAmount: 7200,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: 1791027900321,
      note: '原账',
    );
    final before = (await db.getAllBills()).single;
    await _open(tester, db, bill: before);
    await tester.longPress(_pad('⌫'));
    await settleProviders(tester);
    await _amount(tester, '11');
    await _save(tester);
    expect((await db.getAllBills()).single, before);
    await _actual(tester, '79.20');
    await _save(tester);

    _expectSaved(
      (await db.getAllBills()).single,
      type: 0,
      currency: 'USD',
      account: 'acc_cash',
      amount: 1100,
      actual: 7920,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('确认实扣后更换账户须再确认，不能复用另一个账户金额', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _currency(tester, Currency.usd);
    await _account(tester, '现金');
    await _amount(tester, '10');
    await _actual(tester, '72');
    await _account(tester, '微信');
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    await _actual(tester, '72.10');
    await _save(tester);
    _expectSaved(
      (await db.getAllBills()).single,
      type: 0,
      currency: 'USD',
      account: 'acc_wechat',
      amount: 1000,
      actual: 7210,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('取消账户实际金额窗口不会将输入当作已确认', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _currency(tester, Currency.usd);
    await _account(tester, '现金');
    await _amount(tester, '10');
    await _tap(tester, _key('entry-account-amount'));
    await tester.enterText(_key('account-amount-input'), '72');
    tester.testTextInput.hide();
    await _tap(tester, find.text('取消'));
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('关闭币种选择面板保留金额及备注，并仍可保存原币种', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _note(tester, '取消切币');
    await _amount(tester, '10.29');
    await _tap(tester, _key('entry-currency'));
    Navigator.of(tester.element(find.text('美元 USD'))).pop();
    await settleProviders(tester);
    await _save(tester);
    final saved = (await db.getAllBills()).single;
    expect(saved.currency, 'CNY');
    expect(saved.amount, 1029);
    expect(saved.note, '取消切币');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final sameCurrency in [true, false]) {
    testWidgets('查重${sameCurrency ? '提醒同币相似账单' : '不将人民币相似数额误算为美元重复'}', (
      tester,
    ) async {
      final db = await _seed();
      await db.upsertBill(
        id: 'old',
        type: 0,
        amount: 1000,
        currency: sameCurrency ? 'USD' : 'CNY',
        accountId: sameCurrency ? 'usd' : 'acc_cash',
        dateMs: DateTime.now().millisecondsSinceEpoch,
        note: '旧账',
      );
      await _open(tester, db);
      await _currency(tester, Currency.usd);
      await _account(tester, '美元钱包');
      await _amount(tester, '10');
      await _save(tester);
      if (sameCurrency) {
        expect(find.text('可能重复记账'), findsOneWidget);
        expect((await db.getAllBills()).length, 1);
        await _tap(tester, find.text('取消'));
        expect((await db.getAllBills()).length, 1);
        await _save(tester);
        await _tap(tester, find.text('仍要保存'));
      } else {
        expect(find.text('可能重复记账'), findsNothing);
      }
      expect((await db.getAllBills()).length, 2);
      expect(
        (await db.getAllBills()).where((b) => b.note != '旧账').single.currency,
        'USD',
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('跨币再记保留币种账户但清空金额备注，下一笔须重新确认实扣', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _currency(tester, Currency.usd);
    await _account(tester, '现金');
    await _amount(tester, '10');
    await _actual(tester, '72');
    await _note(tester, '第一笔');
    await _tap(tester, _pad('再记'));
    expect(find.byType(EditBillPage), findsOneWidget);
    expect((await db.getAllBills()).length, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.widgetWithText(ActionChip, '美元 USD'), findsOneWidget);
    await _amount(tester, '11');
    await _save(tester);
    expect((await db.getAllBills()).length, 1);
    await _actual(tester, '79.20');
    await _save(tester);
    expect((await db.getAllBills()).length, 2);
    expect(
      (await db.getAllBills())
          .where((b) => b.note.isEmpty)
          .single
          .accountAmount,
      7920,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('360宽屏可滚动使用币种与实扣胶囊并正常保存', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await _seed();
    await _open(tester, db);
    await _currency(tester, Currency.usd);
    await _account(tester, '现金');
    await _amount(tester, '10');
    await _actual(tester, '72');
    expect(_pad('保存').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _save(tester);
    expect((await db.getAllBills()).single.accountAmount, 7200);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('开启AA后拒绝切外币，人民币平分账单仍可正常创建', (tester) async {
    final db = await _seed(paired: true);
    await _open(tester, db);
    await _tap(tester, find.widgetWithText(FilterChip, '🤝 AA平分'));
    await _currency(tester, Currency.usd);
    expect(find.widgetWithText(ActionChip, '人民币 CNY'), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, '🤝 AA平分'))
          .selected,
      isTrue,
    );
    await _amount(tester, '10');
    await _save(tester);

    final bill = (await db.getAllBills()).single;
    expect(bill.currency, 'CNY');
    expect(bill.accountAmount, bill.amount);
    expect(bill.isAa, isTrue);
    expect(bill.aaGroupId, isNotNull);
    expect((await db.getAllAaGroups()).single.totalAmount, 1000);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('人民币交易选择USD账户后不能开启AA，普通跨币保存不产生共享组', (tester) async {
    final db = await _seed(paired: true);
    await _open(tester, db);
    await _account(tester, '美元钱包');
    final aaChip = find.widgetWithText(FilterChip, '🤝 AA平分');
    if (aaChip.evaluate().isNotEmpty) {
      await _tap(tester, aaChip);
      expect(tester.widget<FilterChip>(aaChip).selected, isFalse);
    }
    await _amount(tester, '72');
    await _actual(tester, '10');
    await _save(tester);

    _expectSaved(
      (await db.getAllBills()).single,
      type: 0,
      currency: 'CNY',
      account: 'usd',
      amount: 7200,
      actual: 1000,
    );
    expect(await db.getAllAaGroups(), isEmpty);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('AA开关只限制支出，切为收入后可选择USD正常保存', (tester) async {
    final db = await _seed(paired: true);
    await _open(tester, db);
    await _tap(tester, find.widgetWithText(FilterChip, '🤝 AA平分'));
    await _tap(tester, find.text('收入'));
    await _currency(tester, Currency.usd);
    await _account(tester, '美元钱包');
    await _amount(tester, '10');
    await _save(tester);

    _expectSaved(
      (await db.getAllBills()).single,
      type: 1,
      currency: 'USD',
      account: 'usd',
      amount: 1000,
      actual: 1000,
    );
    expect(await db.getAllAaGroups(), isEmpty);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final change in ['币种', '类型']) {
    testWidgets('已确认实扣切换$change再切回后仍须重新确认', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      await _currency(tester, Currency.usd);
      await _account(tester, '现金');
      await _amount(tester, '10');
      await _actual(tester, '72');
      if (change == '币种') {
        await _currency(tester, Currency.eur);
        await _currency(tester, Currency.usd);
      } else {
        await _tap(tester, find.text('收入'));
        await _tap(tester, find.text('支出'));
      }
      expect(find.widgetWithText(ActionChip, '实扣 CNY 待确认'), findsOneWidget);
      await _save(tester);
      expect(await db.getAllBills(), isEmpty);
      await _actual(tester, '72.10');
      await _save(tester);

      _expectSaved(
        (await db.getAllBills()).single,
        type: 0,
        currency: 'USD',
        account: 'acc_cash',
        amount: 1000,
        actual: 7210,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('默认账户展示后新增更靠前同币账户不会静默换绑', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    expect(find.widgetWithText(ActionChip, '💵 现金'), findsOneWidget);
    await tester.runAsync(
      () => db.upsertAccount(
        id: 'new-first-cny',
        name: '新首位账户',
        emoji: '💳',
        type: 0,
        initBalance: 0,
        includeNetWorth: true,
        sort: -1000,
        currency: 'CNY',
      ),
    );
    await settleProviders(tester);
    expect(find.widgetWithText(ActionChip, '💵 现金'), findsOneWidget);
    await _amount(tester, '10');
    await _save(tester);

    _expectSaved(
      (await db.getAllBills()).single,
      type: 0,
      currency: 'CNY',
      account: 'acc_cash',
      amount: 1000,
      actual: 1000,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
