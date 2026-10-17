import 'dart:async';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/exchange/transfer_rate_prefill.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
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

/// 可控的 C-13 预填入口：报价与刷新时机由测试决定，绝不触网。
class _FakePrefill implements TransferRatePrefill {
  _FakePrefill([this.quoteFn]);

  RateQuote? Function(Currency base, Currency target)? quoteFn;
  Completer<void>? gate;
  int ensureFreshCalls = 0;
  final List<VoidCallback> _listeners = [];

  @override
  bool get loading => gate != null && !gate!.isCompleted;

  @override
  RateQuote? quote(Currency base, Currency target) =>
      quoteFn?.call(base, target);

  @override
  Future<void> ensureFresh(Currency base, Currency target) async {
    ensureFreshCalls++;
    await gate?.future;
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void publish() {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}

RateQuote _quote(
  Currency base,
  Currency target,
  String rate, {
  bool manual = false,
  bool stale = false,
}) => RateQuote(
  base: base,
  quote: target,
  ratio: RateRatio.parse(rate),
  isManual: manual,
  isStale: stale,
  source: manual ? '手动设置' : 'Frankfurter / ECB',
  quotedAt: DateTime.utc(2026, 10, 16),
  fetchedAt: DateTime.utc(2026, 10, 16, 10, 30),
);

String _wallet(Currency currency, [bool second = false]) =>
    '${currency.code}${second ? '备用' : '钱包'}';

Future<TestAppDatabase> _seed() async {
  final db = TestAppDatabase();
  await db.getAllAccounts();
  await db.upsertAccount(
    id: 'acc_cash',
    name: '现金',
    emoji: '💵',
    type: 0,
    initBalance: 0,
    includeNetWorth: true,
    sort: 0,
  );
  await db.upsertAccount(
    id: 'acc_bank',
    name: '银行卡',
    emoji: '🏦',
    type: 1,
    initBalance: 0,
    includeNetWorth: true,
    sort: 1,
  );
  for (final currency in [Currency.usd, Currency.jpy, Currency.eur]) {
    for (final second in [false, true]) {
      await db.upsertAccount(
        id: '${currency.code.toLowerCase()}${second ? '-2' : ''}',
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

Future<void> _open(
  WidgetTester tester,
  TestAppDatabase db, {
  Bill? bill,
  _FakePrefill? rates,
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
    transferRates: rates,
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

String _amountFieldText(WidgetTester tester) =>
    tester
        .widget<TextField>(find.byKey(const ValueKey('account-amount-input')))
        .controller!
        .text;

Future<void> _save(WidgetTester tester) => _tap(tester, _pad('保存'));

void main() {
  for (final sample in [
    (
      source: Currency.cny,
      target: Currency.usd,
      rate: '0.125',
      out: '720',
      candidate: '90.00',
      incoming: 9000,
      direction: '1 CNY ≈ 0.125 USD（约值）',
    ),
    (
      source: Currency.jpy,
      target: Currency.cny,
      rate: '0.049265',
      out: '1000',
      candidate: '49.27',
      incoming: 4927,
      direction: '1 JPY ≈ 0.049265 CNY（约值）',
    ),
    (
      source: Currency.cny,
      target: Currency.usd,
      rate: '0.333333',
      out: '100',
      candidate: '33.33',
      incoming: 3333,
      direction: '1 CNY ≈ 0.333333 USD（约值）',
    ),
  ]) {
    testWidgets(
      '${sample.source.code}→${sample.target.code}候选按完整分数单次舍入并显式确认保存',
      (tester) async {
        final db = await _seed();
        final rates = _FakePrefill(
          (base, target) => _quote(base, target, sample.rate),
        );
        await _open(tester, db, rates: rates);
        await _account(tester, sample.source == Currency.cny
            ? '现金'
            : _wallet(sample.source));
        await _account(
          tester,
          sample.target == Currency.cny ? '现金' : _wallet(sample.target),
          to: true,
        );
        await _amount(tester, sample.out);
        expect(
          find.textContaining('候选 ${sample.candidate}（Frankfurter / ECB）'),
          findsOneWidget,
        );
        await _tap(tester, _key('transfer-received-amount'));
        expect(find.text(sample.direction), findsOneWidget);
        expect(find.textContaining('来源：Frankfurter / ECB'), findsOneWidget);
        expect(find.byKey(const ValueKey('transfer-rate-input')), findsOneWidget);
        expect(_amountFieldText(tester), sample.candidate);
        await _tap(tester, find.text('确认'));
        await settleProviders(tester);
        expect(find.textContaining('候选'), findsNothing);
        await _save(tester);

        final bills = await db.getAllBills();
        expect(bills.single.type, 2);
        expect(bills.single.currency, sample.source.code);
        expect(bills.single.amount, int.parse(sample.out) *
            (sample.source == Currency.jpy ? 1 : 100));
        expect(bills.single.accountAmount, bills.single.amount);
        expect(bills.single.toAccountAmount, sample.incoming);
        final balances = computeExactBalances(
          await db.getAllAccounts(),
          bills,
        );
        expect(
          balances[sample.source == Currency.cny
              ? 'acc_cash'
              : sample.source.code.toLowerCase()],
          BigInt.from(-bills.single.amount),
        );
        expect(
          balances[sample.target == Currency.cny
              ? 'acc_cash'
              : sample.target.code.toLowerCase()],
          BigInt.from(sample.incoming),
        );
        expect(tester.takeException(), isNull);
        await disposePage(tester, db);
      },
    );
  }

  testWidgets('自定义汇率换算入账额，网络候选不再采用', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    await _tap(tester, _key('transfer-received-amount'));
    expect(_amountFieldText(tester), '90.00');
    await tester.enterText(_key('transfer-rate-input'), '0.2');
    await settleProviders(tester);
    expect(_amountFieldText(tester), '144.00');
    await _tap(tester, find.text('确认'));
    await settleProviders(tester);
    await _save(tester);
    expect((await db.getAllBills()).single.toAccountAmount, 14400);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('自定义汇率格式无效提示且保留原金额，改回有效后恢复换算', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    await _tap(tester, _key('transfer-received-amount'));
    await tester.enterText(_key('transfer-rate-input'), '-1');
    await settleProviders(tester);
    expect(find.text('汇率格式无效'), findsOneWidget);
    expect(_amountFieldText(tester), '90.00');
    await tester.enterText(_key('transfer-rate-input'), '0.2');
    await settleProviders(tester);
    expect(find.text('汇率格式无效'), findsNothing);
    expect(_amountFieldText(tester), '144.00');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('直接改实际入账额优先于汇率候选', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    await _tap(tester, _key('transfer-received-amount'));
    await tester.enterText(_key('account-amount-input'), '88.88');
    tester.testTextInput.hide();
    await _tap(tester, find.text('确认'));
    await settleProviders(tester);
    await _save(tester);
    expect((await db.getAllBills()).single.toAccountAmount, 8888);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('新建转账取消预填不产生入账确认，保存被拦且无账单', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    await _tap(tester, _key('transfer-received-amount'));
    expect(_amountFieldText(tester), '90.00');
    await _tap(tester, find.text('取消'));
    await settleProviders(tester);
    expect(find.textContaining('候选 90.00'), findsOneWidget);
    expect(find.text('入账 USD 90.00'), findsNothing);
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('缺汇率提示可人工确认双额', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill();
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    expect(find.textContaining('暂无汇率'), findsOneWidget);
    await _tap(tester, _key('transfer-received-amount'));
    expect(
      find.text('暂无可用汇率：可直接输入入账额，或填写自定义汇率换算。'),
      findsOneWidget,
    );
    await tester.enterText(_key('account-amount-input'), '100');
    tester.testTextInput.hide();
    await _tap(tester, find.text('确认'));
    await settleProviders(tester);
    await _save(tester);
    expect((await db.getAllBills()).single.toAccountAmount, 10000);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('过期网络汇率明确标注仍可确认，手动汇率显示手动来源', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill(
      (base, target) => _quote(base, target, '0.125', stale: true),
    );
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    expect(find.textContaining('已过期'), findsOneWidget);
    await _tap(tester, _key('transfer-received-amount'));
    expect(find.textContaining('汇率已过期'), findsOneWidget);
    await _tap(tester, find.text('确认'));
    await settleProviders(tester);
    expect(find.textContaining('已过期'), findsNothing);
    await _save(tester);
    expect((await db.getAllBills()).single.toAccountAmount, 9000);
    await disposePage(tester, db);

    final db2 = await _seed();
    final manual = _FakePrefill(
      (base, target) => _quote(base, target, '0.2', manual: true),
    );
    await _open(tester, db2, rates: manual);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    expect(find.textContaining('手动汇率'), findsOneWidget);
    await _tap(tester, _key('transfer-received-amount'));
    expect(find.textContaining('来源：手动设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db2);
  });

  testWidgets('迟到刷新只更新候选显示，不覆盖已确认入账', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    await _tap(tester, _key('transfer-received-amount'));
    await _tap(tester, find.text('确认'));
    await settleProviders(tester);
    expect(find.text('入账 USD 90.00'), findsOneWidget);

    rates.quoteFn = (base, target) => _quote(base, target, '0.5');
    rates.publish();
    await settleProviders(tester);
    expect(find.text('入账 USD 90.00'), findsOneWidget);
    expect(find.textContaining('候选'), findsNothing);
    await _save(tester);
    expect((await db.getAllBills()).single.toAccountAmount, 9000);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('换目标账户后旧确认失效，重新确认新入账额', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    await _tap(tester, _key('transfer-received-amount'));
    await _tap(tester, find.text('确认'));
    await settleProviders(tester);
    await _account(tester, 'USD备用', to: true);
    await settleProviders(tester);
    await _save(tester);
    expect(await db.getAllBills(), isEmpty);
    // 同币对候选不变，但旧确认已失效，需重新打开确认。
    expect(find.textContaining('候选 90.00'), findsOneWidget);
    await _tap(tester, _key('transfer-received-amount'));
    expect(_amountFieldText(tester), '90.00');
    await _tap(tester, find.text('确认'));
    await settleProviders(tester);
    await _save(tester);
    final bill = (await db.getAllBills()).single;
    expect(bill.toAccountId, 'usd-2');
    expect(bill.toAccountAmount, 9000);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('历史转账回显已保存双额，刷新汇率不重算旧账', (tester) async {
    final db = await _seed();
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
    final before = (await db.getAllBills()).single;
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, bill: before, rates: rates);
    expect(find.text('入账 USD 10.00'), findsOneWidget);
    await _tap(tester, _key('transfer-received-amount'));
    expect(_amountFieldText(tester), '10.00');
    rates.quoteFn = (base, target) => _quote(base, target, '9.9');
    rates.publish();
    await settleProviders(tester);
    expect(find.text('入账 USD 10.00'), findsOneWidget);
    expect(find.textContaining('候选'), findsNothing);
    await _tap(tester, find.text('取消'));
    await settleProviders(tester);
    await _save(tester);
    final after = (await db.getAllBills()).single;
    expect(after.toAccountAmount, 1000);
    expect(after.amount, 7200);
    expect(after.createdAt, 77);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('同币转账不出现汇率候选与预填弹窗', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, '银行卡', to: true);
    await _amount(tester, '720');
    expect(find.textContaining('候选'), findsNothing);
    expect(find.textContaining('汇率'), findsNothing);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('transfer-received-amount')),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('候选越出int64范围时不预填，手动输入仍可确认', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '200'));
    await _open(tester, db, rates: rates);
    await _account(tester, 'USD钱包');
    await _account(tester, 'JPY钱包', to: true);
    await _amount(tester, '92233720368547758.07');
    expect(find.textContaining('候选'), findsNothing);
    expect(find.textContaining('Frankfurter / ECB'), findsOneWidget);
    await _tap(tester, _key('transfer-received-amount'));
    expect(find.textContaining('超出可保存范围'), findsOneWidget);
    expect(_amountFieldText(tester), isEmpty);
    await tester.enterText(_key('account-amount-input'), '100');
    tester.testTextInput.hide();
    await _tap(tester, find.text('确认'));
    await settleProviders(tester);
    await _save(tester);
    expect((await db.getAllBills()).single.toAccountAmount, 100);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('同一转账签名只请求一次汇率，可用快照后不再请求', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill();
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '720');
    // 缺率时每个本金签名各请求一次：7 / 72 / 720。
    expect(rates.ensureFreshCalls, 3);
    await settleProviders(tester);
    rates.publish();
    await settleProviders(tester);
    expect(rates.ensureFreshCalls, 3);
    // 换账户后签名变化，但已有可用快照，不再重复请求。
    rates.quoteFn = (base, target) => _quote(base, target, '0.125');
    rates.publish();
    await settleProviders(tester);
    expect(find.textContaining('候选 90.00'), findsOneWidget);
    await _account(tester, 'USD备用', to: true);
    await settleProviders(tester);
    expect(rates.ensureFreshCalls, 3);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('表达式未按等号确认时不能打开预填弹窗，候选随求值总额显示', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill((base, target) => _quote(base, target, '0.125'));
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '0.1+0.2');
    // 表达式总额可精确求值，候选按总额显示；但未按等号前不能确认。
    expect(find.textContaining('候选 0.04'), findsOneWidget);
    await _tap(tester, _key('transfer-received-amount'));
    expect(find.byType(AlertDialog), findsNothing);
    await _tap(tester, _pad('='));
    await _tap(tester, _key('transfer-received-amount'));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('关闭页面后迟到的汇率通知不触发异常', (tester) async {
    final db = await _seed();
    final rates = _FakePrefill()..gate = Completer<void>();
    await _open(tester, db, rates: rates);
    await _account(tester, '现金');
    await _account(tester, 'USD钱包', to: true);
    await _amount(tester, '72');
    expect(rates.ensureFreshCalls, 2);
    await disposePage(tester, db);
    rates.gate!.complete();
    await tester.pump();
    rates.publish();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
