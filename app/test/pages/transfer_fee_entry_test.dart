import 'dart:async';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/utils/balance.dart';
import 'package:aa_expense_splitter/utils/report.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

Finder _key(String name) => find.byKey(ValueKey(name));
Finder _pad(String text) =>
    find.descendant(of: find.byType(NumberPad), matching: find.text(text));
Finder _dialogText(String text) => find.descendant(
  of: find.byType(AlertDialog).last,
  matching: find.text(text),
);

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
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await settleProviders(tester);
}

Future<AppDatabase> _seed([AppDatabase? database]) async {
  final db = database ?? TestAppDatabase();
  await db.getAllAccounts();
  for (final code in ['USD', 'JPY']) {
    for (final suffix in ['', '-2']) {
      await db.upsertAccount(
        id: '${code.toLowerCase()}$suffix',
        name: '$code${suffix.isEmpty ? '钱包' : '备用'}',
        emoji: '💳',
        type: 0,
        initBalance: 0,
        includeNetWorth: true,
        sort: 10,
        currency: code,
      );
    }
  }
  await db.upsertCategory(
    id: 'fee-child-category',
    name: '手续费细分',
    emoji: '🪙',
    kind: 0,
    sort: 0,
    parentId: 'cat_food',
  );
  return db;
}

Future<void> _open(
  WidgetTester tester,
  AppDatabase db, {
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
    await _tap(tester, _pad(character));
  }
}

Future<void> _clearAmount(WidgetTester tester) async {
  await tester.ensureVisible(_pad('⌫'));
  await tester.longPress(_pad('⌫'));
  await settleProviders(tester);
}

Future<void> _fee(WidgetTester tester, String amount) async {
  await _tap(tester, _key('transfer-fee-button'));
  expect(find.text('转账手续费'), findsOneWidget);
  await tester.enterText(_key('transfer-fee-input'), amount);
  tester.testTextInput.hide();
  await _tap(tester, _dialogText('确认'));
}

Future<void> _incoming(WidgetTester tester, String amount) async {
  await _tap(tester, _key('transfer-received-amount'));
  await tester.enterText(_key('account-amount-input'), amount);
  tester.testTextInput.hide();
  await _tap(tester, _dialogText('确认'));
}

Future<void> _note(WidgetTester tester, String note) async {
  await tester.enterText(find.byType(TextField), note);
  tester.testTextInput.hide();
  await tester.pump();
}

Future<void> _save(WidgetTester tester) => _tap(tester, _pad('保存'));

Future<Bill> _parent(AppDatabase db) async =>
    (await db.getAllBills()).singleWhere((bill) => bill.type == 2);

Future<({Bill parent, Bill fee})> _original(AppDatabase db) async {
  await db.saveTransferWithFee(
    id: 'original',
    amount: 10000,
    toAccountAmount: 10000,
    dateMs: DateTime(2026, 10, 8, 12).millisecondsSinceEpoch,
    note: '原转账',
    feeAmount: 125,
    feeCategoryId: 'cat_food',
    expectedSource: (await db.getAccount('acc_cash'))!,
    expectedTarget: (await db.getAccount('acc_bank'))!,
  );
  return (
    parent: await _parent(db),
    fee: (await db.getTransferFee('original'))!,
  );
}

Future<Map<String, Object?>> _snapshot(AppDatabase db) async => {
  for (final table in [
    'accounts',
    'bills',
    'categories',
    'aa_groups',
    'settlements',
    'meta_entries',
  ])
    table: [
      for (final row
          in await db
              .customSelect('SELECT * FROM "$table" ORDER BY rowid')
              .get())
        row.data,
    ],
};

Future<void> _expectMoney(
  AppDatabase db, {
  String source = 'acc_cash',
  String target = 'acc_bank',
  String currency = 'CNY',
  int principal = 10000,
  int incoming = 10000,
  int feeAmount = 125,
}) async {
  final parent = await _parent(db);
  final fee = await db.getTransferFee(parent.id);
  expect(parent.amount, principal);
  expect(parent.accountAmount, principal);
  expect(parent.toAccountAmount, incoming);
  expect(parent.accountId, source);
  expect(parent.toAccountId, target);
  expect(parent.currency, currency);
  final rows = await db.getAllBills();
  if (feeAmount == 0) {
    expect(rows.map((bill) => bill.id), [parent.id]);
    expect(fee == null || fee.deletedAt != null, isTrue);
  } else {
    expect(rows.length, 2);
    expect(fee, isNotNull);
    expect(fee!.feeTransferId, parent.id);
    expect(fee.type, 0);
    expect(fee.amount, feeAmount);
    expect(fee.accountAmount, feeAmount);
    expect(fee.accountId, source);
    expect(fee.currency, currency);
    expect(fee.toAccountId, isNull);
    expect(fee.isAa, isFalse);
    expect(fee.aaGroupId, isNull);
    expect(fee.settlementId, isNull);
    expect(fee.dateMs, parent.dateMs);
  }
  final balances = computeExactBalances(await db.getAllAccounts(), rows);
  expect(balances[source], -BigInt.from(principal) - BigInt.from(feeAmount));
  expect(balances[target], BigInt.from(incoming));
  final report = buildReport(
    bills: rows,
    categories: await db.getAllCategories(),
    filter: ReportFilter(currency: currency),
  );
  expect(report.expense, BigInt.from(feeAmount));
  expect(report.income, BigInt.zero);
  expect(report.expenseBills.length, feeAmount == 0 ? 0 : 1);
}

class _BlockedSaveDatabase extends TestAppDatabase {
  final release = Completer<void>();
  int calls = 0;

  @override
  Future<void> saveTransferWithFee({
    required String id,
    required int amount,
    required int toAccountAmount,
    required int dateMs,
    String note = '',
    required int feeAmount,
    String? feeCategoryId,
    required Account expectedSource,
    required Account expectedTarget,
    Bill? expectedTransfer,
    Bill? expectedFee,
  }) async {
    calls++;
    await release.future;
    await super.saveTransferWithFee(
      id: id,
      amount: amount,
      toAccountAmount: toAccountAmount,
      dateMs: dateMs,
      note: note,
      feeAmount: feeAmount,
      feeCategoryId: feeCategoryId,
      expectedSource: expectedSource,
      expectedTarget: expectedTarget,
      expectedTransfer: expectedTransfer,
      expectedFee: expectedFee,
    );
  }
}

void main() {
  testWidgets('同币本金与二级分类手续费合存，余额扣总额报表只计一次费用', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, '银行卡', to: true);
    await _amount(tester, '100');
    await _tap(tester, _key('transfer-fee-button'));
    await tester.enterText(_key('transfer-fee-input'), '1.25');
    tester.testTextInput.hide();
    await _tap(tester, _key('transfer-fee-category'));
    await _tap(tester, _key('category-root-cat_food'));
    await _tap(tester, _key('category-child-fee-child-category'));
    await _tap(tester, _dialogText('确认'));
    if (_key('transfer-fee-input').evaluate().isNotEmpty) {
      await _tap(tester, _dialogText('确认'));
    }
    expect(
      tester.widget<Text>(_key('transfer-total-debit')).data,
      '总扣款 ¥ 101.25',
    );
    await _save(tester);
    await _expectMoney(db);
    final fee = (await db.getTransferFee((await _parent(db)).id))!;
    expect(fee.categoryId, 'fee-child-category');
    expect(find.byType(EditBillPage), findsNothing);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('编辑修改费用取消为零后重加复用原费用身份，历史不会额外计费', (tester) async {
    final db = await _seed();
    final original = await _original(db);
    await _open(tester, db, bill: original.parent);
    await _fee(tester, '2.50');
    await _clearAmount(tester);
    await _amount(tester, '110');
    await _note(tester, '修改本金与手续费');
    await _save(tester);
    await _expectMoney(db, principal: 11000, incoming: 11000, feeAmount: 250);
    expect((await db.getTransferFee('original'))!.id, original.fee.id);

    await _open(tester, db, bill: await _parent(db));
    await _fee(tester, '0');
    await _save(tester);
    await _expectMoney(db, principal: 11000, incoming: 11000, feeAmount: 0);
    final cancelled = (await db.getTransferFee('original'))!;
    expect(cancelled.id, original.fee.id);
    expect(cancelled.feeDeletedWithTransferAt, isNull);

    await _open(tester, db, bill: await _parent(db));
    await _fee(tester, '0.01');
    await _save(tester);
    await _expectMoney(db, principal: 11000, incoming: 11000, feeAmount: 1);
    final restored = (await db.getTransferFee('original'))!;
    expect(restored.id, original.fee.id);
    expect(restored.createdAt, original.fee.createdAt);
    expect((await db.select(db.bills).get()).length, 2);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final sample in [
    (
      source: '现金',
      target: 'USD钱包',
      sourceId: 'acc_cash',
      targetId: 'usd',
      currency: 'CNY',
      amount: '72',
      incoming: '10.29',
      fee: '0.31',
      principalUnits: 7200,
      incomingUnits: 1029,
      feeUnits: 31,
    ),
    (
      source: 'USD钱包',
      target: 'JPY钱包',
      sourceId: 'usd',
      targetId: 'jpy',
      currency: 'USD',
      amount: '10',
      incoming: '1501',
      fee: '0.29',
      principalUnits: 1000,
      incomingUnits: 1501,
      feeUnits: 29,
    ),
  ]) {
    testWidgets('${sample.currency}跨币费用仅扣来源，目标保留手动实际入账', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      await _account(tester, sample.source);
      await _account(tester, sample.target, to: true);
      await _amount(tester, sample.amount);
      await _incoming(tester, sample.incoming);
      await _fee(tester, sample.fee);
      await _save(tester);
      await _expectMoney(
        db,
        source: sample.sourceId,
        target: sample.targetId,
        currency: sample.currency,
        principal: sample.principalUnits,
        incoming: sample.incomingUnits,
        feeAmount: sample.feeUnits,
      );
      expect(
        (await db.getTransferFee((await _parent(db)).id))!.categoryId,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final code in ['CNY', 'JPY']) {
    testWidgets('$code费用拒绝空负数表达式指数过精度越界，原草稿不落库', (tester) async {
      final db = await _seed();
      await _open(tester, db);
      if (code == 'JPY') await _account(tester, 'JPY钱包');
      await _account(tester, code == 'JPY' ? 'JPY备用' : '银行卡', to: true);
      await _amount(tester, '100');
      await _tap(tester, _key('transfer-fee-button'));
      for (final invalid in [
        '',
        '-1',
        '1+2',
        '1e3',
        code == 'JPY' ? '1.0' : '1.001',
        code == 'JPY' ? '9223372036854775808' : '92233720368547758.08',
      ]) {
        await tester.enterText(_key('transfer-fee-input'), invalid);
        tester.testTextInput.hide();
        await _tap(tester, _dialogText('确认'));
        expect(_key('transfer-fee-input'), findsOneWidget);
        expect(await db.getAllBills(), isEmpty);
      }
      await tester.enterText(
        _key('transfer-fee-input'),
        code == 'JPY' ? '1' : '0.01',
      );
      tester.testTextInput.hide();
      await _tap(tester, _dialogText('确认'));
      await _save(tester);
      await _expectMoney(
        db,
        source: code == 'JPY' ? 'jpy' : 'acc_cash',
        target: code == 'JPY' ? 'jpy-2' : 'acc_bank',
        currency: code,
        principal: code == 'JPY' ? 100 : 10000,
        incoming: code == 'JPY' ? 100 : 10000,
        feeAmount: 1,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('新转账显式零手续费不创建子账，原无费转账仍可直接保存', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, '银行卡', to: true);
    await _amount(tester, '100');
    await _fee(tester, '0');
    await _save(tester);
    await _expectMoney(db, feeAmount: 0);
    expect(await db.getTransferFee((await _parent(db)).id), isNull);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('费用对话框取消保留已有金额与分类，备注更新不需重复确认费用', (tester) async {
    final db = await _seed();
    final fixture = await _original(db);
    await _open(tester, db, bill: fixture.parent);
    await _tap(tester, _key('transfer-fee-button'));
    expect(
      tester.widget<TextField>(_key('transfer-fee-input')).controller!.text,
      '1.25',
    );
    await tester.enterText(_key('transfer-fee-input'), '9.99');
    tester.testTextInput.hide();
    await _tap(tester, _dialogText('取消'));
    await _note(tester, '保留原手续费');
    await _save(tester);
    await _expectMoney(db);
    expect(
      (await db.getTransferFee('original'))!.categoryId,
      fixture.fee.categoryId,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('手续费取消连点只关闭自身对话框，编辑页与原手续费草稿保留', (tester) async {
    final db = await _seed();
    final fixture = await _original(db);
    await _open(tester, db, bill: fixture.parent);
    final before = await _snapshot(db);
    await _tap(tester, _key('transfer-fee-button'));
    await tester.enterText(_key('transfer-fee-input'), '9.99');
    tester.testTextInput.hide();
    final cancel = tester
        .widget<TextButton>(
          find.ancestor(
            of: _dialogText('取消'),
            matching: find.byType(TextButton),
          ),
        )
        .onPressed!;
    await tester.runAsync(() async {
      // A second event may already be queued before the route pop animates.
      cancel();
      cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await settleProviders(tester);
    expect(_key('transfer-fee-input'), findsNothing);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(find.byType(NumberPad), findsOneWidget);
    expect(await _snapshot(db), before);
    await _tap(tester, _key('transfer-fee-button'));
    expect(
      tester.widget<TextField>(_key('transfer-fee-input')).controller!.text,
      '1.25',
    );
    await _tap(tester, _dialogText('取消'));
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final returnToOriginal in [false, true]) {
    testWidgets('来源同币换账户${returnToOriginal ? '再换回' : ''}也必须重新确认正费用', (
      tester,
    ) async {
      final db = await _seed();
      await _open(tester, db);
      await _account(tester, '银行卡', to: true);
      await _amount(tester, '100');
      await _fee(tester, '1.25');
      await _account(tester, '微信');
      if (returnToOriginal) await _account(tester, '现金');
      await _save(tester);
      expect(await db.getAllBills(), isEmpty);
      expect(find.textContaining('手续费待确认'), findsWidgets);
      await _fee(tester, '1.25');
      await _save(tester);
      await _expectMoney(
        db,
        source: returnToOriginal ? 'acc_cash' : 'acc_wechat',
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('只改目标本金备注保留来源手续费确认与独立金额', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, '银行卡', to: true);
    await _amount(tester, '100');
    await _fee(tester, '1.25');
    await _account(tester, '微信', to: true);
    await _clearAmount(tester);
    await _amount(tester, '101');
    await _note(tester, '费用不随本金变化');
    await _save(tester);
    await _expectMoney(
      db,
      target: 'acc_wechat',
      principal: 10100,
      incoming: 10100,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('费用对话框等待时来源后台换币，迟到确认不将美元分误认为日元', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _account(tester, 'JPY钱包', to: true);
    await _amount(tester, '10');
    await _incoming(tester, '1500');
    await _tap(tester, _key('transfer-fee-button'));
    await tester.enterText(_key('transfer-fee-input'), '0.29');
    tester.testTextInput.hide();

    await tester.runAsync(() async {
      final source = (await db.getAccount('usd'))!;
      await db.upsertAccount(
        id: source.id,
        name: source.name,
        emoji: source.emoji,
        type: source.type,
        initBalance: source.initBalance,
        includeNetWorth: source.includeNetWorth,
        sort: source.sort,
        currency: 'JPY',
      );
    });
    await settleProviders(tester);
    final external = await _snapshot(db);
    await _tap(tester, _dialogText('确认'));
    expect(await _snapshot(db), external);
    expect(await db.getAllBills(), isEmpty);

    // 重新打开应使用新来源币种和零值，不能继承迟到的 29 美分候选。
    await _tap(tester, _key('transfer-fee-button'));
    expect(
      tester.widget<TextField>(_key('transfer-fee-input')).controller!.text,
      '0',
    );
    await _tap(tester, _dialogText('取消'));
    expect(await _snapshot(db), external);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('正费用来源换币后显示待确认，新币对话框初始零避免重解释旧最小单位', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, '银行卡', to: true);
    await _amount(tester, '100');
    await _fee(tester, '1.25');
    await _account(tester, 'JPY钱包');
    await _incoming(tester, '100');
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    expect(find.textContaining('手续费待确认'), findsWidgets);
    await _tap(tester, _key('transfer-fee-button'));
    expect(
      tester.widget<TextField>(_key('transfer-fee-input')).controller!.text,
      '0',
    );
    await tester.enterText(_key('transfer-fee-input'), '2');
    tester.testTextInput.hide();
    await _tap(tester, _dialogText('确认'));
    await _save(tester);
    await _expectMoney(
      db,
      source: 'jpy',
      target: 'acc_bank',
      currency: 'JPY',
      principal: 100,
      incoming: 10000,
      feeAmount: 2,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('再记只保留转账账户，清空本金备注手续费且第二笔不重复扣费', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, '银行卡', to: true);
    await _amount(tester, '100');
    await _fee(tester, '1.25');
    await _note(tester, '第一笔');
    await _tap(tester, _pad('再记'));
    expect(find.byType(EditBillPage), findsOneWidget);
    expect((await db.getAllBills()).length, 2);
    await _amount(tester, '20');
    await _save(tester);
    final rows = await db.getAllBills();
    expect(rows.length, 3);
    final second = rows.singleWhere(
      (bill) => bill.type == 2 && bill.note.isEmpty,
    );
    expect(await db.getTransferFee(second.id), isNull);
    final balances = computeExactBalances(await db.getAllAccounts(), rows);
    expect(balances['acc_cash'], BigInt.from(-12125));
    expect(balances['acc_bank'], BigInt.from(12000));
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final cancelled in [false, true]) {
    testWidgets('${cancelled ? '已取消' : '活动'}费用历史的父转账禁止改成支出或收入', (tester) async {
      final db = await _seed();
      final fixture = await _original(db);
      if (cancelled) {
        await db.saveTransferWithFee(
          id: fixture.parent.id,
          amount: fixture.parent.amount,
          toAccountAmount: fixture.parent.toAccountAmount!,
          dateMs: fixture.parent.dateMs,
          note: fixture.parent.note,
          feeAmount: 0,
          expectedSource: (await db.getAccount('acc_cash'))!,
          expectedTarget: (await db.getAccount('acc_bank'))!,
          expectedTransfer: fixture.parent,
          expectedFee: fixture.fee,
        );
      }
      final before = await _snapshot(db);
      await _open(tester, db, bill: await _parent(db));
      for (final label in ['支出', '收入']) {
        await _tap(tester, find.text(label));
        expect(find.text('含手续费历史的转账不能改为收支'), findsOneWidget);
        expect(_key('transfer-fee-button'), findsOneWidget);
      }
      expect(await _snapshot(db), before);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final changed in ['parent', 'fee', 'source', 'target']) {
    testWidgets('编辑期间$changed后台变化拒绝旧草稿，六张表不发生额外修改', (tester) async {
      final db = await _seed();
      final fixture = await _original(db);
      final cachedAccounts = await db.getAllAccounts();
      await _open(
        tester,
        db,
        bill: fixture.parent,
        fixedAccounts: cachedAccounts,
      );
      await _fee(tester, '2.50');
      await _note(tester, '不应覆盖后台更新');
      await tester.runAsync(() async {
        if (changed == 'parent') {
          await db.customStatement('UPDATE bills SET note = ? WHERE id = ?', [
            '后台新备注',
            fixture.parent.id,
          ]);
        } else if (changed == 'fee') {
          await db.customStatement(
            'UPDATE bills SET amount = ?, account_amount = ? WHERE id = ?',
            [126, 126, fixture.fee.id],
          );
        } else {
          await db.customStatement(
            'UPDATE accounts SET init_balance = init_balance + 1 WHERE id = ?',
            [changed == 'source' ? 'acc_cash' : 'acc_bank'],
          );
        }
      });
      await settleProviders(tester);
      final afterExternalChange = await _snapshot(db);
      await _tap(tester, _key('transfer-fee-button'));
      expect(
        tester.widget<TextField>(_key('transfer-fee-input')).controller!.text,
        '2.50',
      );
      await _tap(tester, _dialogText('取消'));
      await _save(tester);
      expect(find.byType(EditBillPage), findsOneWidget);
      expect(await _snapshot(db), afterExternalChange);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('首次确认无费用后后台添加费用，保存不能自动采用新快照覆盖费用', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'original',
      type: 2,
      amount: 10000,
      accountAmount: 10000,
      toAccountAmount: 10000,
      accountId: 'acc_cash',
      toAccountId: 'acc_bank',
      dateMs: 100,
      note: '原无费转账',
    );
    final original = await _parent(db);
    await _open(tester, db, bill: original);
    await _fee(tester, '2.50');
    await tester.runAsync(() async {
      await db.saveTransferWithFee(
        id: original.id,
        amount: 10000,
        toAccountAmount: 10000,
        dateMs: original.dateMs,
        note: original.note,
        feeAmount: 125,
        expectedSource: (await db.getAccount('acc_cash'))!,
        expectedTarget: (await db.getAccount('acc_bank'))!,
        expectedTransfer: original,
      );
    });
    await settleProviders(tester);
    final external = await _snapshot(db);
    await _tap(tester, _key('transfer-fee-button'));
    expect(
      tester.widget<TextField>(_key('transfer-fee-input')).controller!.text,
      '2.50',
    );
    await _tap(tester, _dialogText('取消'));
    await _save(tester);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(await _snapshot(db), external);
    expect((await db.getTransferFee(original.id))!.amount, 125);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final kind in [0, 1]) {
    testWidgets('原${kind == 0 ? '支出' : '收入'}改为带费转账保留账单ID并清除原收支分类', (
      tester,
    ) async {
      final db = await _seed();
      await db.upsertBill(
        id: 'convert',
        type: kind,
        amount: 10000,
        accountId: 'acc_cash',
        categoryId: kind == 0 ? 'cat_food' : 'inc_salary',
        dateMs: 100,
        note: '原收支',
        createdAt: 77,
      );
      final before = (await db.getAllBills()).single;
      await _open(tester, db, bill: before);
      await _tap(tester, find.text('转账'));
      await _account(tester, '银行卡', to: true);
      await _fee(tester, '1.25');
      await _save(tester);
      await _expectMoney(db);
      final after = await _parent(db);
      expect(after.id, 'convert');
      expect(after.createdAt, 77);
      expect(after.categoryId, isNull);
      expect(after.note, '原收支');
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('重复记账确认等待期间来源账户变化，继续保存仍拒绝且六表不变', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'similar',
      type: 2,
      amount: 10000,
      accountId: 'acc_cash',
      toAccountId: 'acc_bank',
      dateMs: DateTime.now().millisecondsSinceEpoch,
      note: '已存在转账',
    );
    final cached = await db.getAllAccounts();
    await _open(tester, db, fixedAccounts: cached);
    await _account(tester, '银行卡', to: true);
    await _amount(tester, '100');
    await _fee(tester, '1.25');
    await _save(tester);
    expect(find.text('可能重复记账'), findsOneWidget);
    await tester.runAsync(
      () => db.customStatement(
        'UPDATE accounts SET init_balance = init_balance + 1 WHERE id = ?',
        ['acc_cash'],
      ),
    );
    await settleProviders(tester);
    final external = await _snapshot(db);
    await _tap(tester, find.text('仍要保存'));
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(await _snapshot(db), external);
    expect((await db.getAllBills()).single.id, 'similar');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('等待保存期间连续点击只发起一个原子保存且只生成一个费用子账', (tester) async {
    final blocked = _BlockedSaveDatabase();
    final db = await _seed(blocked);
    await _open(tester, db);
    addTearDown(() {
      if (!blocked.release.isCompleted) blocked.release.complete();
    });
    await _account(tester, '银行卡', to: true);
    await _amount(tester, '100');
    await _fee(tester, '1.25');
    await _save(tester);
    expect(blocked.calls, 1);
    final absorber = tester
        .element(find.byType(NumberPad))
        .findAncestorWidgetOfExactType<AbsorbPointer>();
    expect(absorber, isNotNull);
    expect(absorber!.absorbing, isTrue);
    await tester.runAsync(() async {
      // Bypass pointer absorption to check the save method's own reentry guard.
      tester.widget<NumberPad>(find.byType(NumberPad)).onSave();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await settleProviders(tester);
    expect(blocked.calls, 1);
    await tester.runAsync(() async {
      blocked.release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await settleProviders(tester);
    await _expectMoney(db);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('360窄屏费用与总扣款可滚动访问，键盘保存仍可见无溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'USD钱包');
    await _account(tester, 'JPY钱包', to: true);
    await _amount(tester, '10');
    await _incoming(tester, '1501');
    await _fee(tester, '0.29');
    await tester.ensureVisible(_key('transfer-total-debit'));
    expect(_key('transfer-total-debit').hitTestable(), findsOneWidget);
    expect(
      tester.widget<Text>(_key('transfer-total-debit')).data,
      allOf(startsWith('总扣款 '), contains('10.29')),
    );
    expect(_pad('保存').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _save(tester);
    await _expectMoney(
      db,
      source: 'usd',
      target: 'jpy',
      currency: 'USD',
      principal: 1000,
      incoming: 1501,
      feeAmount: 29,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('本金与费用各为int64最大值时总扣款以BigInt精确显示和统计', (tester) async {
    final db = await _seed();
    await _open(tester, db);
    await _account(tester, 'JPY钱包');
    await _account(tester, 'JPY备用', to: true);
    await _amount(tester, '9223372036854775807');
    await _fee(tester, '9223372036854775807');
    expect(find.textContaining('18,446,744,073,709,551,614'), findsOneWidget);
    await _save(tester);
    await _expectMoney(
      db,
      source: 'jpy',
      target: 'jpy-2',
      currency: 'JPY',
      principal: 9223372036854775807,
      incoming: 9223372036854775807,
      feeAmount: 9223372036854775807,
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
