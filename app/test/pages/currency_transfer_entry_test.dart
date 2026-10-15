import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/balance.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

Finder _key(String name) => find.byKey(ValueKey(name));
Finder _pad(String text) =>
    find.descendant(of: find.byType(NumberPad), matching: find.text(text));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; finder.evaluate().isEmpty && attempt < 10; attempt++) {
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

String _wallet(Currency currency, [bool second = false]) =>
    '${currency.code}${second ? '备用' : '钱包'}';
String _accountId(Currency currency, [bool second = false]) =>
    currency == Currency.cny
    ? (second ? 'acc_bank' : 'acc_cash')
    : '${currency.code.toLowerCase()}${second ? '-2' : ''}';

Future<TestAppDatabase> _seed() async {
  final db = TestAppDatabase();
  await db.getAllAccounts();
  for (final currency in Currency.values.where((c) => c != Currency.cny)) {
    for (final second in [false, true]) {
      await db.upsertAccount(
        id: _accountId(currency, second),
        name: _wallet(currency, second),
        emoji: '💳',
        type: 0,
        initBalance: 0,
        includeNetWorth: true,
        sort: 10 + currency.index * 2 + (second ? 1 : 0),
        currency: currency.code,
      );
    }
  }
  return db;
}

String _name(Currency currency, [bool second = false]) =>
    currency == Currency.cny
    ? (second ? '银行卡' : '现金')
    : _wallet(currency, second);

Future<void> _open(
  WidgetTester tester,
  TestAppDatabase db, {
  Bill? bill,
  List<Account>? fixedAccounts,
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
    overrides: [
      if (fixedAccounts != null)
        accountsProvider.overrideWith((ref) => Stream.value(fixedAccounts)),
    ],
  );
  await _tap(tester, find.text('开始'));
  if (bill == null) await _tap(tester, find.text('转账'));
}

Future<void> _account(
  WidgetTester tester,
  String name, {
  bool to = false,
}) async {
  await _tap(tester, _key(to ? 'transfer-to-account' : 'entry-account'));
  await _tap(tester, find.widgetWithText(ListTile, name));
}

Future<void> _amount(WidgetTester tester, String text) async {
  for (final character in text.split('')) {
    await _tap(tester, _pad(character == '-' ? '−' : character));
  }
}

Future<void> _clear(WidgetTester tester) async {
  await tester.ensureVisible(_pad('⌫'));
  await tester.longPress(_pad('⌫'));
  await settleProviders(tester);
}

Future<void> _incoming(WidgetTester tester, String text) async {
  await _tap(tester, _key('transfer-received-amount'));
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

Future<void> _expectTransfer(
  TestAppDatabase db, {
  required Currency currency,
  required String source,
  required String target,
  required int outgoing,
  required int incoming,
}) async {
  final bills = await db.getAllBills();
  final bill = bills.single;
  expect(bill.type, 2);
  expect(bill.currency, currency.code);
  expect(bill.accountId, source);
  expect(bill.toAccountId, target);
  expect(bill.amount, outgoing);
  expect(bill.accountAmount, outgoing);
  expect(bill.toAccountAmount, incoming);
  expect(bill.categoryId, isNull);
  expect(bill.isAa, isFalse);
  expect(bill.aaGroupId, isNull);
  expect(bill.settlementId, isNull);
  expect(await db.getAllAaGroups(), isEmpty);
  final balances = computeExactBalances(await db.getAllAccounts(), bills);
  expect(balances[source], BigInt.from(-outgoing));
  expect(balances[target], BigInt.from(incoming));
}

Future<Bill> _original(TestAppDatabase db) async {
  await db.upsertBill(
    id: 'original',
    type: 2,
    accountId: 'acc_cash',
    toAccountId: 'usd',
    currency: 'CNY',
    amount: 7200,
    accountAmount: 7200,
    toAccountAmount: 1000,
    dateMs: DateTime(2026, 10, 3, 14, 25).millisecondsSinceEpoch,
    note: '原转账',
    createdAt: 77,
  );
  return (await db.getAllBills()).single;
}

Future<Map<String, Object?>> _snapshot(TestAppDatabase db) async => {
  'accounts': {
    for (final row in await db.select(db.accounts).get()) row.id: row.toJson(),
  },
  'bills': {
    for (final row in await db.select(db.bills).get()) row.id: row.toJson(),
  },
  'categories': {
    for (final row in await db.select(db.categories).get())
      row.id: row.toJson(),
  },
  'aaGroups': {
    for (final row in await db.select(db.aaGroups).get()) row.id: row.toJson(),
  },
  'settlements': {
    for (final row in await db.select(db.settlements).get())
      row.id: row.toJson(),
  },
  'meta': {
    for (final row in await db.select(db.metaEntries).get())
      row.key: row.toJson(),
  },
};

void main() {
  for (final currency in Currency.values) {
    testWidgets('${currency.code}两真实钱包转账自动按本币精度等额保存', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      await _account(tester, _name(currency));
      await _account(tester, _name(currency, true), to: true);
      await _amount(tester, currency == Currency.jpy ? '123' : '10.29');
      await _save(tester);

      final units = currency == Currency.jpy ? 123 : 1029;
      await _expectTransfer(
        db,
        currency: currency,
        source: _accountId(currency),
        target: _accountId(currency, true),
        outgoing: units,
        incoming: units,
      );
      expect(find.byType(EditBillPage), findsNothing);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final sample in [
    (
      source: Currency.cny,
      target: Currency.usd,
      out: '720',
      into: '100',
      outUnits: 72000,
      inUnits: 10000,
    ),
    (
      source: Currency.usd,
      target: Currency.jpy,
      out: '10',
      into: '1500',
      outUnits: 1000,
      inUnits: 1500,
    ),
    (
      source: Currency.jpy,
      target: Currency.eur,
      out: '123',
      into: '0.29',
      outUnits: 123,
      inUnits: 29,
    ),
  ]) {
    testWidgets('${sample.source.code}转${sample.target.code}分别确认两账户金额', (
      tester,
    ) async {
      final db = await _seed();
      await _open(tester, db);
      await _account(tester, _name(sample.source));
      await _account(tester, _name(sample.target), to: true);
      await _amount(tester, sample.out);
      await _save(tester);
      expect(await db.getAllBills(), isEmpty);
      await _incoming(tester, sample.into);
      await _save(tester);

      await _expectTransfer(
        db,
        currency: sample.source,
        source: _accountId(sample.source),
        target: _accountId(sample.target),
        outgoing: sample.outUnits,
        incoming: sample.inUnits,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final currency in [Currency.usd, Currency.jpy]) {
    testWidgets('${currency.code}入账拒绝空零负数指数越界及过精度，取消不入账', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      await _account(tester, _name(currency), to: true);
      await _amount(tester, '72');
      await _tap(tester, _key('transfer-received-amount'));
      for (final invalid in [
        '',
        '0',
        '-1',
        '1e3',
        currency == Currency.jpy ? '1.0' : '1.001',
        currency == Currency.jpy
            ? '9223372036854775808'
            : '92233720368547758.08',
      ]) {
        await tester.enterText(_key('account-amount-input'), invalid);
        tester.testTextInput.hide();
        await _tap(tester, find.text('确认'));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(await db.getAllBills(), isEmpty);
      }
      await tester.enterText(_key('account-amount-input'), '10');
      tester.testTextInput.hide();
      await _tap(tester, find.text('取消'));
      await _save(tester);
      expect(await db.getAllBills(), isEmpty);
      await _incoming(tester, currency == Currency.jpy ? '1531' : '10.29');
      await _save(tester);
      await _expectTransfer(
        db,
        currency: Currency.cny,
        source: 'acc_cash',
        target: _accountId(currency),
        outgoing: 7200,
        incoming: currency == Currency.jpy ? 1531 : 1029,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final change in ['出账额', '出账账户', '入账账户']) {
    testWidgets('新增跨币转账确认后改$change必须重新确认入账', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      await _account(tester, 'USD钱包', to: true);
      await _amount(tester, '72');
      await _incoming(tester, '10');
      if (change == '出账额') {
        await _clear(tester);
        await _amount(tester, '73');
      } else if (change == '出账账户') {
        await _account(tester, '银行卡');
      } else {
        await _account(tester, 'USD备用', to: true);
      }
      await _save(tester);
      expect(await db.getAllBills(), isEmpty);
      await _incoming(tester, '10.29');
      await _save(tester);
      await _expectTransfer(
        db,
        currency: Currency.cny,
        source: change == '出账账户' ? 'acc_bank' : 'acc_cash',
        target: change == '入账账户' ? 'usd-2' : 'usd',
        outgoing: change == '出账额' ? 7300 : 7200,
        incoming: 1029,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('跨币确认后改账户再改回不能恢复旧入账确认', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '72');
    await _incoming(tester, '10');
    await _account(tester, 'USD备用', to: true);
    await _account(tester, 'USD钱包', to: true);
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    await _incoming(tester, '10.29');
    await _save(tester);
    expect((await db.getAllBills()).single.toAccountAmount, 1029);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('已有跨币转账只改备注保留三金额与身份时间', (tester) async {
    final db = await _seed();
    final before = await _original(db);
    await _open(tester, db, bill: before);
    await _note(tester, '更正转账备注');
    await _save(tester);
    final after = (await db.getAllBills()).single;
    expect(after.note, '更正转账备注');
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

  testWidgets('已有跨币转账只改日期保留原两侧金额', (tester) async {
    final db = await _seed();
    final before = await _original(db);
    await _open(tester, db, bill: before);
    await _tap(tester, _key('entry-date'));
    final dialog = find.byType(DatePickerDialog);
    final localizations = MaterialLocalizations.of(tester.element(dialog));
    await _tap(tester, find.byTooltip(localizations.inputDateModeButtonLabel));
    await tester.enterText(
      find.descendant(
        of: find.byType(InputDatePickerFormField),
        matching: find.byType(TextField),
      ),
      localizations.formatCompactDate(DateTime(2026, 10, 4)),
    );
    tester.testTextInput.hide();
    await _tap(
      tester,
      find.descendant(
        of: dialog,
        matching: find.text(localizations.okButtonLabel),
      ),
    );
    await _tap(
      tester,
      find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.text(localizations.okButtonLabel),
      ),
    );
    await _save(tester);
    final after = (await db.getAllBills()).single;
    expect(after.dateMs, DateTime(2026, 10, 4, 14, 25).millisecondsSinceEpoch);
    expect(
      after.toJson()
        ..remove('updatedAt')
        ..remove('dateMs'),
      before.toJson()
        ..remove('updatedAt')
        ..remove('dateMs'),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final change in ['出账额', '出账账户', '入账账户', '改同币来源', '改同币目标']) {
    testWidgets('已有跨币改$change未重确认不修改历史，确认后两侧余额正确', (tester) async {
      final db = await _seed();
      final before = await _original(db);
      await _open(tester, db, bill: before);
      if (change == '出账额') {
        await _clear(tester);
        await _amount(tester, '73');
      } else if (change == '出账账户') {
        await _account(tester, '银行卡');
      } else if (change == '入账账户') {
        await _account(tester, 'USD备用', to: true);
      } else if (change == '改同币来源') {
        await _account(tester, 'USD备用');
      } else {
        await _account(tester, '银行卡', to: true);
      }
      await _save(tester);
      expect((await db.getAllBills()).single, before);
      final sameCurrency = change.startsWith('改同币');
      if (sameCurrency) {
        await _incoming(tester, '71');
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.enterText(_key('account-amount-input'), '72');
        tester.testTextInput.hide();
        await _tap(tester, find.text('确认'));
      } else {
        await _incoming(tester, '10.29');
      }
      await _save(tester);
      await _expectTransfer(
        db,
        currency: change == '改同币来源' ? Currency.usd : Currency.cny,
        source: change == '改同币来源'
            ? 'usd-2'
            : change == '出账账户'
            ? 'acc_bank'
            : 'acc_cash',
        target: change == '改同币目标'
            ? 'acc_bank'
            : change == '入账账户'
            ? 'usd-2'
            : 'usd',
        outgoing: change == '出账额' ? 7300 : 7200,
        incoming: sameCurrency ? 7200 : 1029,
      );
      final after = (await db.getAllBills()).single;
      expect(after.id, before.id);
      expect(after.createdAt, before.createdAt);
      expect(after.note, before.note);
      expect(after.dateMs, before.dateMs);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('已有同币USD转账可编辑出账额并同步三金额', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'same-usd',
      type: 2,
      amount: 1000,
      currency: 'USD',
      accountId: 'usd',
      toAccountId: 'usd-2',
      dateMs: 100,
      createdAt: 77,
    );
    final before = (await db.getAllBills()).single;
    await _open(tester, db, bill: before);
    await _clear(tester);
    await _amount(tester, '10.29');
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.usd,
      source: 'usd',
      target: 'usd-2',
      outgoing: 1029,
      incoming: 1029,
    );
    expect((await db.getAllBills()).single.createdAt, 77);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('跨币历史缺少入账额不能猜金额，显式补充后才可修改', (tester) async {
    final db = await _seed();
    await _original(db);
    await db.customStatement(
      'UPDATE bills SET to_account_amount = NULL WHERE id = ?',
      ['original'],
    );
    final before = (await db.getAllBills()).single;
    await _open(tester, db, bill: before);
    await _note(tester, '补充实际入账');
    await _save(tester);
    expect((await db.getAllBills()).single, before);
    await _incoming(tester, '10.29');
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.cny,
      source: 'acc_cash',
      target: 'usd',
      outgoing: 7200,
      incoming: 1029,
    );
    expect((await db.getAllBills()).single.createdAt, 77);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final invalid in ['currency', 'account_amount']) {
    testWidgets('历史转账$invalid与出账账户金额不一致时保持只读', (tester) async {
      final db = await _seed();
      await _original(db);
      await db.customStatement('UPDATE bills SET $invalid = ? WHERE id = ?', [
        invalid == 'currency' ? 'USD' : 7199,
        'original',
      ]);
      final before = (await db.getAllBills()).single;
      await _open(tester, db, bill: before);
      expect(find.byType(NumberPad), findsNothing);
      expect(_key('transfer-received-amount'), findsNothing);
      expect((await db.getAllBills()).single, before);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('旧CNY空入账字段转账仍可修改并保存同币等额', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'legacy',
      type: 2,
      amount: 529,
      accountId: 'acc_cash',
      toAccountId: 'acc_bank',
      dateMs: 100,
    );
    await db.customStatement(
      'UPDATE bills SET to_account_amount = NULL WHERE id = ?',
      ['legacy'],
    );
    final before = (await db.getAllBills()).single;
    await _open(tester, db, bill: before);
    await _clear(tester);
    await _amount(tester, '6.31');
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.cny,
      source: 'acc_cash',
      target: 'acc_bank',
      outgoing: 631,
      incoming: 631,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('跨币再记保留两个账户并清空金额备注和入账确认', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _account(tester, 'JPY钱包', to: true);
    await _amount(tester, '10');
    await _incoming(tester, '1500');
    await _note(tester, '第一笔');
    await _tap(tester, _pad('再记'));
    expect(find.byType(EditBillPage), findsOneWidget);
    expect((await db.getAllBills()).length, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(
      find.descendant(
        of: _key('entry-account'),
        matching: find.textContaining('USD钱包'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('transfer-to-account'),
        matching: find.textContaining('JPY钱包'),
      ),
      findsOneWidget,
    );
    await _amount(tester, '11');
    await _save(tester);
    expect((await db.getAllBills()).length, 1);
    await _incoming(tester, '1650');
    await _save(tester);
    final bills = await db.getAllBills();
    expect(bills.length, 2);
    final second = bills.singleWhere((bill) => bill.note.isEmpty);
    expect(second.currency, 'USD');
    expect(second.amount, 1100);
    expect(second.accountAmount, 1100);
    expect(second.toAccountAmount, 1650);
    final balances = computeExactBalances(await db.getAllAccounts(), bills);
    expect(balances['usd'], BigInt.from(-2100));
    expect(balances['jpy'], BigInt.from(3150));
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('USD转账表达式0.1加0.2准确保存29分入账且未求值不能确认', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _account(tester, 'EUR钱包', to: true);
    await _amount(tester, '0.1+0.2');
    await _tap(tester, _key('transfer-received-amount'));
    expect(find.byType(AlertDialog), findsNothing);
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    await _tap(tester, _pad('='));
    await _incoming(tester, '0.29');
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.usd,
      source: 'usd',
      target: 'eur',
      outgoing: 30,
      incoming: 29,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('跨币两侧int64最大值独立解析，不经浮点损失末位', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _account(tester, 'JPY钱包', to: true);
    await _amount(tester, '92233720368547758.07');
    await _incoming(tester, '9223372036854775807');
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.usd,
      source: 'usd',
      target: 'jpy',
      outgoing: 9223372036854775807,
      incoming: 9223372036854775807,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('JPY出账点小数键不生成小数，改来源时不暗中舍入已有数字', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _account(tester, 'JPY备用', to: true);
    await _amount(tester, '10.29');
    await _account(tester, 'JPY钱包');
    expect(find.text('10.29'), findsOneWidget);
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    await _clear(tester);
    await _amount(tester, '123');
    await _tap(tester, _pad('.'));
    expect(find.text('123.'), findsNothing);
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.jpy,
      source: 'jpy',
      target: 'jpy-2',
      outgoing: 123,
      incoming: 123,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('输入两侧金额后退出编辑不写入任何账单', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '72');
    await _incoming(tester, '10');
    await _tap(tester, find.byIcon(Icons.close));
    expect(await db.getAllBills(), isEmpty);
    expect(find.byType(EditBillPage), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('账户选择面板取消保留原两侧确认，可继续保存', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '72');
    await _incoming(tester, '10');
    await _tap(tester, _key('transfer-to-account'));
    Navigator.of(tester.element(find.text('选择转入账户'))).pop();
    await settleProviders(tester);
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.cny,
      source: 'acc_cash',
      target: 'usd',
      outgoing: 7200,
      incoming: 1000,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('首次展示的默认转入账户固定，账户列表重排不替用户换钱包', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    expect(
      find.descendant(
        of: _key('transfer-to-account'),
        matching: find.textContaining('微信'),
      ),
      findsOneWidget,
    );
    await tester.runAsync(
      () => db.upsertAccount(
        id: 'acc_bank',
        name: '银行卡',
        emoji: '🏦',
        type: 1,
        initBalance: 0,
        includeNetWorth: true,
        sort: -100,
      ),
    );
    await settleProviders(tester);
    await _amount(tester, '10');
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.cny,
      source: 'acc_cash',
      target: 'acc_wechat',
      outgoing: 1000,
      incoming: 1000,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('跨币入账确认后切类型再切回必须重新确认', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '72');
    await _incoming(tester, '10');
    await _tap(tester, find.text('支出'));
    await _tap(tester, find.text('转账'));
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    await _incoming(tester, '10.29');
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.cny,
      source: 'acc_cash',
      target: 'usd',
      outgoing: 7200,
      incoming: 1029,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('转账来源与目标都排除AA挂账其他AA类型及未知币种账户', (tester) async {
    final db = await _seed();
    for (final id in [kAaCreditAccountId, 'another-aa', 'unknown']) {
      await db.upsertAccount(
        id: id,
        name: id,
        emoji: '🤝',
        type: id == 'unknown' ? 0 : 4,
        initBalance: 0,
        includeNetWorth: false,
        sort: -100,
      );
    }
    await db.customStatement('UPDATE accounts SET currency = ? WHERE id = ?', [
      'BTC',
      'unknown',
    ]);
    await _open(tester, db);
    for (final to in [false, true]) {
      await _tap(tester, _key(to ? 'transfer-to-account' : 'entry-account'));
      for (final id in [kAaCreditAccountId, 'another-aa', 'unknown']) {
        expect(find.widgetWithText(ListTile, id), findsNothing);
      }
      await _tap(tester, find.widgetWithText(ListTile, to ? '银行卡' : '现金'));
    }
    await _amount(tester, '10');
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.cny,
      source: 'acc_cash',
      target: 'acc_bank',
      outgoing: 1000,
      incoming: 1000,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('转账不能给同一外币账户自己转账', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '10');
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    await _account(tester, 'USD备用', to: true);
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.usd,
      source: 'usd',
      target: 'usd-2',
      outgoing: 1000,
      incoming: 1000,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('只有一个外币真实账户不能转账且不自动使用AA挂账', (tester) async {
    final db = await _seed();
    for (final account in await db.getAllAccounts()) {
      if (account.id != 'usd') await db.deleteAccount(account.id);
    }
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _amount(tester, '10');
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final to in [false, true]) {
    testWidgets('确认后${to ? '入账' : '出账'}账户被删除必须重选，不能改用默认钱包', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      await _account(tester, 'USD钱包');
      await _account(tester, 'JPY钱包', to: true);
      await _amount(tester, '10');
      await _incoming(tester, '1500');
      await tester.runAsync(() => db.deleteAccount(to ? 'jpy' : 'usd'));
      await settleProviders(tester);
      await _save(tester);
      expect(await db.getAllBills(), isEmpty);
      expect(find.byType(EditBillPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final change in ['币种', 'AA类型']) {
    testWidgets('确认后目标账户$change变化拒绝旧确认，保持无账单写入', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      await _account(tester, 'USD钱包', to: true);
      await _amount(tester, '72');
      await _incoming(tester, '10');
      await tester.runAsync(() async {
        if (change == '币种') {
          await db.upsertAccount(
            id: 'usd',
            name: 'USD钱包',
            emoji: '💳',
            type: 0,
            initBalance: 0,
            includeNetWorth: true,
            sort: 10,
            currency: 'JPY',
          );
        } else {
          // 模拟旧库或外部变更产生的异常外币 AA 钱包，不能继续使用旧确认。
          await db.customStatement(
            'UPDATE accounts SET type = 4 WHERE id = ?',
            ['usd'],
          );
        }
      });
      await settleProviders(tester);
      await _save(tester);
      expect(await db.getAllBills(), isEmpty);
      expect(await db.getAllAaGroups(), isEmpty);
      expect(find.byType(EditBillPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('重复确认期间目标币种改变而Provider仍旧时，事务拒绝且六表不变', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'similar',
      type: 2,
      amount: 7200,
      accountId: 'acc_cash',
      toAccountId: 'acc_bank',
      dateMs: DateTime.now().millisecondsSinceEpoch,
      note: '已存在的同额转账',
    );
    // 固定界面缓存，确保失败来自保存事务读库核对，而非 watch 刷新后前置拒绝。
    final cachedAccounts = await db.getAllAccounts();
    await _open(tester, db, fixedAccounts: cachedAccounts);
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '72');
    await _incoming(tester, '10');
    await _save(tester);
    expect(find.text('可能重复记账'), findsOneWidget);
    expect((await db.getAllBills()).single.id, 'similar');

    // 原相似账单指向其他账户，USD 钱包无引用，修改币种是合法外部操作。
    await tester.runAsync(
      () => db.upsertAccount(
        id: 'usd',
        name: 'USD钱包',
        emoji: '💳',
        type: 0,
        initBalance: 0,
        includeNetWorth: true,
        sort: 10,
        currency: 'JPY',
      ),
    );
    await settleProviders(tester);
    expect((await db.getAccount('usd'))!.currency, 'JPY');
    expect(cachedAccounts.singleWhere((a) => a.id == 'usd').currency, 'USD');
    final afterAccountChange = await _snapshot(db);
    await _tap(tester, find.text('仍要保存'));

    expect(find.text('所选账户已变化，请重新选择账户'), findsOneWidget);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(await _snapshot(db), afterAccountChange);
    expect((await db.getAllBills()).single.id, 'similar');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('跨币转账删除撤销同时撤销恢复两个账户余额', (tester) async {
    final db = await _seed();
    final before = await _original(db);
    await _open(tester, db, bill: before);
    await _tap(tester, find.byIcon(Icons.delete_outline));
    await _tap(tester, find.text('删除'));
    expect(await db.getAllBills(), isEmpty);
    var balances = computeExactBalances(
      await db.getAllAccounts(),
      await db.getAllBills(),
    );
    expect(balances['acc_cash'], BigInt.zero);
    expect(balances['usd'], BigInt.zero);
    final deleted = await (db.select(
      db.bills,
    )..where((row) => row.id.equals(before.id))).getSingle();
    expect(deleted.deletedAt, isNotNull);
    expect(deleted.updatedAt, greaterThanOrEqualTo(before.updatedAt));
    await db.restoreTransferWithFee(
      expectedTransfer: deleted,
      expectedFee: null,
    );
    final restored = (await db.getAllBills()).single;
    expect(restored.updatedAt, greaterThanOrEqualTo(deleted.updatedAt));
    // 专用删除 / 恢复记录更新时间，其余全部字段与原交易保持一致。
    expect(restored.toJson(), {
      ...before.toJson(),
      'updatedAt': restored.updatedAt,
    });
    await _expectTransfer(
      db,
      currency: Currency.cny,
      source: 'acc_cash',
      target: 'usd',
      outgoing: 7200,
      incoming: 1000,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('360宽屏转账两账户入账确认日期与保存均可操作且无溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _account(tester, 'JPY钱包', to: true);
    await _amount(tester, '10');
    expect(_key('transfer-received-amount').hitTestable(), findsOneWidget);
    await _incoming(tester, '1500');
    expect(_key('entry-date'), findsOneWidget);
    expect(_pad('保存').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _save(tester);
    await _expectTransfer(
      db,
      currency: Currency.usd,
      source: 'usd',
      target: 'jpy',
      outgoing: 1000,
      incoming: 1500,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
