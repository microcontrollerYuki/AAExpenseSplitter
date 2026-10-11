import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/providers.dart';

import '../helpers/test_support.dart';

Finder get _detail => find.byType(BillDetailPage);
Finder _detailText(String text) =>
    find.descendant(of: _detail, matching: find.text(text));

int _dateMs() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, 8, 12).millisecondsSinceEpoch;
}

Future<void> _account(AppDatabase db, String id, String currency) =>
    db.upsertAccount(
      id: id,
      name: '$currency 钱包',
      emoji: '💳',
      type: 3,
      initBalance: 0,
      includeNetWorth: true,
      sort: 20,
      currency: currency,
    );

Future<Bill> _bill(
  AppDatabase db,
  String id, {
  int type = 0,
  int amount = 1000,
  String currency = 'CNY',
  String accountId = 'acc_cash',
  int? accountAmount,
  String? toAccountId,
  int? toAccountAmount,
}) async {
  await db.upsertBill(
    id: id,
    type: type,
    amount: amount,
    currency: currency,
    accountId: accountId,
    accountAmount: accountAmount,
    toAccountId: toAccountId,
    toAccountAmount: toAccountAmount,
    categoryId: type == 2 ? null : (type == 1 ? 'inc_salary' : 'cat_food'),
    dateMs: _dateMs(),
    note: id,
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

Future<void> _openDetail(WidgetTester tester) async {
  await tester.tap(find.text('打开测试详情'));
  await settleProviders(tester);
  expect(find.byType(BottomSheet), findsOneWidget);
  expect(_detail, findsOneWidget);
}

Future<void> _selectCurrency(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('currency-filter')));
  await settleProviders(tester);
  await tester.tap(find.text(label).last);
  await settleProviders(tester);
}

void _expectSummary(String label, String value) {
  final column = find
      .ancestor(of: find.text(label), matching: find.byType(Column))
      .first;
  expect(
    find.descendant(of: column, matching: find.text(value)),
    findsOneWidget,
  );
}

void _narrowLargeText(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.8;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void _expectWithinScreen(WidgetTester tester, Finder text) {
  final rect = tester.getRect(text);
  expect(rect.left, greaterThanOrEqualTo(-0.1));
  expect(rect.right, lessThanOrEqualTo(320.1));
}

void main() {
  testWidgets('明细保留三币原额，统计菜单只切换月日摘要且不改账单', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD');
    await _account(db, 'jpy', 'JPY');
    await _bill(db, '人民币早餐');
    await _bill(db, '人民币工资', type: 1, amount: 3000);
    await _bill(db, '美元午餐', amount: 2000, currency: 'USD', accountId: 'usd');
    await _bill(
      db,
      '美元工资',
      type: 1,
      amount: 5000,
      currency: 'USD',
      accountId: 'usd',
    );
    await _bill(db, '日元晚餐', amount: 1531, currency: 'JPY', accountId: 'jpy');
    await _bill(
      db,
      '日元工资',
      type: 1,
      amount: 2000,
      currency: 'JPY',
      accountId: 'jpy',
    );
    await _bill(
      db,
      '跨币转账',
      type: 2,
      amount: 72000,
      toAccountId: 'usd',
      toAccountAmount: 10000,
    );
    final before = await db.getAllBills();
    await pumpPage(tester, const BillsPage(), db: db);

    _expectSummary('收入', '+30.00');
    _expectSummary('支出', '10.00');
    _expectSummary('结余', '+20.00');
    expect(find.text('支出 10.00'), findsOneWidget);
    expect(find.text('-10.00'), findsOneWidget);
    expect(find.text('-USD 20.00'), findsOneWidget);
    expect(find.text('-JPY 1,531'), findsOneWidget);
    expect(find.text('¥ 720.00\n→ USD 100.00'), findsOneWidget);

    await _selectCurrency(tester, '美元 USD');
    _expectSummary('收入', '+USD 50.00');
    _expectSummary('支出', 'USD 20.00');
    _expectSummary('结余', '+USD 30.00');
    expect(find.text('支出 USD 20.00'), findsOneWidget);
    expect(find.text('支出 10.00'), findsNothing);
    expect(find.text('人民币早餐'), findsOneWidget);
    expect(find.text('美元午餐'), findsOneWidget);
    expect(find.text('日元晚餐'), findsOneWidget);

    await _selectCurrency(tester, '日元 JPY');
    _expectSummary('收入', '+JPY 2,000');
    _expectSummary('支出', 'JPY 1,531');
    _expectSummary('结余', '+JPY 469');
    expect(find.text('支出 JPY 1,531'), findsOneWidget);
    expect(find.text('-USD 20.00'), findsOneWidget);
    expect(find.text('-JPY 15.31'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BillsPage)),
    );
    expect(container.read(selectedCurrencyProvider), 'JPY');

    await _selectCurrency(tester, '人民币 CNY');
    _expectSummary('结余', '+20.00');
    expect(await db.getAllBills(), before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final example in [
    ('CNY', 1000, '-¥ 10.00'),
    ('USD', 1000, '-USD 10.00'),
    ('JPY', 1531, '-JPY 1,531'),
  ]) {
    testWidgets('${example.$1}详情以原币显示金额和精度', (tester) async {
      final db = TestAppDatabase();
      await db.getAllAccounts();
      await _account(db, 'wallet', example.$1);
      final bill = await _bill(
        db,
        '${example.$1}原币账单',
        amount: example.$2,
        currency: example.$1,
        accountId: 'wallet',
      );
      await pumpPage(tester, _host(bill), db: db);
      await _openDetail(tester);

      expect(_detailText(example.$3), findsOneWidget);
      expect(_detailText(example.$1), findsOneWidget);
      if (example.$1 != 'CNY') {
        expect(_detailText('-¥ 10.00'), findsNothing);
      }
      expect((await db.getAllBills()).single, bill);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final type in [0, 1]) {
    testWidgets('跨币${type == 0 ? '消费' : '收入'}详情分别显示USD原额与人民币实收付额', (
      tester,
    ) async {
      final db = TestAppDatabase();
      await db.getAllAccounts();
      final bill = await _bill(
        db,
        '美元交易人民币账户',
        type: type,
        currency: 'USD',
        accountAmount: 7200,
      );
      await pumpPage(tester, _host(bill), db: db);
      await _openDetail(tester);

      expect(_detailText('${type == 0 ? '-' : '+'}USD 10.00'), findsOneWidget);
      expect(_detailText(type == 0 ? '实际扣款' : '实际入账'), findsOneWidget);
      expect(_detailText('¥ 72.00'), findsOneWidget);
      expect(_detailText('USD'), findsOneWidget);
      expect(_detailText('USD 72.00'), findsNothing);
      expect(_detailText('${type == 0 ? '-' : '+'}¥ 10.00'), findsNothing);
      expect((await db.getAllBills()).single, bill);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('跨币转账详情显示出账人民币720和入账美元100，查看不改变两额', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD');
    final bill = await _bill(
      db,
      '人民币换美元',
      type: 2,
      amount: 72000,
      toAccountId: 'usd',
      toAccountAmount: 10000,
    );
    await pumpPage(tester, _host(bill), db: db);
    await _openDetail(tester);

    expect(_detailText('¥ 720.00'), findsWidgets);
    expect(_detailText('USD 100.00'), findsOneWidget);
    expect(_detailText('转出金额'), findsOneWidget);
    expect(_detailText('转入金额'), findsOneWidget);
    expect(_detailText('USD 720.00'), findsNothing);
    expect(_detailText('¥ 100.00'), findsNothing);
    expect((await db.getAllBills()).single, bill);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('历史跨币转账缺入账额明确待确认，不猜测金额或改写记录', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'usd', 'USD');
    await _bill(
      db,
      '历史缺入账',
      type: 2,
      amount: 72000,
      toAccountId: 'usd',
      toAccountAmount: 10000,
    );
    await db.customStatement(
      'UPDATE bills SET to_account_amount = NULL WHERE id = ?',
      ['历史缺入账'],
    );
    final bill = (await db.getAllBills()).single;
    await pumpPage(tester, const BillsPage(), db: db);
    expect(find.text('¥ 720.00\n→ 入账待确认'), findsOneWidget);
    await tester.tap(find.text('转账'));
    await settleProviders(tester);

    expect(_detailText('待确认（缺少有效入账金额）'), findsOneWidget);
    expect(_detailText('¥ 720.00'), findsWidgets);
    expect(_detailText('USD 720.00'), findsNothing);
    expect(_detailText('USD 100.00'), findsNothing);
    expect((await db.getAllBills()).single, bill);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final type in [0, 2]) {
    testWidgets('历史${type == 0 ? '消费' : '转账'}缺出账账户时不把实际额伪装成原币', (tester) async {
      final db = TestAppDatabase();
      await db.getAllAccounts();
      await _account(db, 'usd', 'USD');
      await _bill(
        db,
        '缺来源账户',
        type: type,
        amount: type == 0 ? 1000 : 72000,
        currency: type == 0 ? 'USD' : 'CNY',
        accountAmount: type == 0 ? 7200 : 72000,
        toAccountId: type == 2 ? 'usd' : null,
        toAccountAmount: type == 2 ? 10000 : null,
      );
      // 模拟旧导入文件的孤立引用；DAO 不允许新建这样的记录。
      await db.customStatement(
        'UPDATE bills SET account_id = ?, currency = ?, amount = ?, '
        'account_amount = ?, to_account_amount = NULL WHERE id = ?',
        ['missing', 'USD', 1000, 7200, '缺来源账户'],
      );
      final before = (await db.getAllBills()).single;
      await pumpPage(tester, const BillsPage(), db: db);
      expect(find.textContaining('USD 72.00'), findsNothing);
      if (type == 2) {
        expect(find.text('出账待确认\n→ 入账待确认'), findsOneWidget);
      } else {
        expect(find.text('-USD 10.00'), findsOneWidget);
      }
      await tester.tap(find.text(type == 2 ? '转账' : '缺来源账户'));
      await settleProviders(tester);

      expect(
        _detailText(type == 0 ? '-USD 10.00' : 'USD 10.00'),
        findsOneWidget,
      );
      expect(
        _detailText(type == 0 ? '待确认（账户缺失）' : '待确认（出账账户缺失）'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _detail,
          matching: find.textContaining('USD 72.00'),
        ),
        findsNothing,
      );
      if (type == 2) {
        expect(_detailText('待确认（缺少有效入账金额）'), findsOneWidget);
      }
      expect((await db.getAllBills()).single, before);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  for (final failed in [false, true]) {
    testWidgets('分类${failed ? '读取失败' : '尚未加载'}时不把内部往来收入显示为真实月收入', (
      tester,
    ) async {
      final internal = mkBill(
        '内部往来',
        type: 1,
        amount: 4950,
        categoryId: 'cat_aa_marker',
        dateMs: _dateMs(),
        note: '内部应收记录',
      );
      addTearDown(() async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();
      });
      await tester.pumpWidget(
        ProviderScope(
          retry: (retryCount, error) => null,
          overrides: [
            monthBillsProvider.overrideWith((ref) => Stream.value([internal])),
            accountsProvider.overrideWith(
              (ref) => Stream.value([mkAccount('acc_cash')]),
            ),
            categoriesProvider.overrideWith(
              (ref) => failed
                  ? Stream<List<Category>>.error('分类读取失败')
                  : const Stream<List<Category>>.empty(),
            ),
          ],
          child: localizedApp(const BillsPage()),
        ),
      );
      // 加载动画不能 pumpAndSettle；只等待流首帧，不等待不会结束的动画。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('内部应收记录'), findsOneWidget);
      expect(find.text('+49.50'), findsOneWidget); // 仅账单行，不能再出现在摘要。
      expect(find.text('收入'), findsNothing);
      expect(find.text('结余'), findsNothing);
      if (failed) {
        expect(find.text('读取分类失败，请稍后重试'), findsOneWidget);
      } else {
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final failed in [false, true]) {
    testWidgets('账单${failed ? '读取失败' : '尚未加载'}且分类已就绪时不显示零收入或零结余摘要', (
      tester,
    ) async {
      addTearDown(() async {
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        await tester.pump();
      });
      await tester.pumpWidget(
        ProviderScope(
          retry: (retryCount, error) => null,
          overrides: [
            monthBillsProvider.overrideWith(
              (ref) => failed
                  ? Stream<List<Bill>>.error('boom')
                  : const Stream<List<Bill>>.empty(),
            ),
            accountsProvider.overrideWith(
              (ref) => Stream.value([mkAccount('acc_cash')]),
            ),
            categoriesProvider.overrideWith(
              (ref) => Stream.value(const <Category>[]),
            ),
          ],
          child: localizedApp(const BillsPage()),
        ),
      );
      // 只推进流的首帧；加载分支的动画不会自行结束。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('收入'), findsNothing);
      expect(find.text('结余'), findsNothing);
      if (failed) {
        expect(find.text('读取失败：boom'), findsWidgets);
      } else {
        expect(find.byType(CircularProgressIndicator), findsWidgets);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('切换月份等待或读取失败时隐藏旧摘要，新月数据到达后恢复正确金额', (tester) async {
    final now = DateTime.now();
    final oldMonth = DateTime(now.year, now.month, 1);
    final nextMonth = DateTime(now.year, now.month + 1, 1);
    final oldBill = mkBill(
      'old-month',
      amount: 1000,
      dateMs: DateTime(oldMonth.year, oldMonth.month, 8).millisecondsSinceEpoch,
      note: '旧月消费',
    );
    final nextBill = mkBill(
      'next-month',
      amount: 2000,
      dateMs: DateTime(
        nextMonth.year,
        nextMonth.month,
        8,
      ).millisecondsSinceEpoch,
      note: '新月消费',
    );
    final controller = StreamController<List<Bill>>();
    addTearDown(() async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();
      await controller.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        retry: (retryCount, error) => null,
        overrides: [
          monthBillsProvider.overrideWith((ref) {
            final selected = ref.watch(selectedMonthProvider);
            return selected == oldMonth
                ? Stream.value([oldBill])
                : controller.stream;
          }),
          accountsProvider.overrideWith(
            (ref) => Stream.value([mkAccount('acc_cash')]),
          ),
          categoriesProvider.overrideWith(
            (ref) => Stream.value(const <Category>[]),
          ),
        ],
        child: localizedApp(const BillsPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _expectSummary('支出', '10.00');
    _expectSummary('结余', '-10.00');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BillsPage)),
    );
    container.read(selectedMonthProvider.notifier).selectMonth(nextMonth);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final nextTitle = '${nextMonth.year}年${nextMonth.month}月';
    expect(find.text(nextTitle), findsOneWidget);
    expect(find.text('收入'), findsNothing);
    expect(find.text('结余'), findsNothing);
    expect(find.text('旧月消费'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    controller.addError('boom');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(nextTitle), findsOneWidget);
    expect(find.text('收入'), findsNothing);
    expect(find.text('结余'), findsNothing);
    expect(find.text('旧月消费'), findsNothing);
    expect(find.text('读取失败：boom'), findsWidgets);

    controller.add([nextBill]);
    await settleProviders(tester);
    _expectSummary('收入', '0.00');
    _expectSummary('支出', '20.00');
    _expectSummary('结余', '-20.00');
    expect(find.text(nextTitle), findsOneWidget);
    expect(find.text('新月消费'), findsOneWidget);
    expect(find.text('旧月消费'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未知历史币种保留代码和最小单位，摘要与详情不伪装人民币', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _bill(db, '未知币种账单', amount: 12345);
    await db.customStatement('UPDATE bills SET currency = ? WHERE id = ?', [
      'XTS',
      '未知币种账单',
    ]);
    final before = (await db.getAllBills()).single;
    await pumpPage(tester, const BillsPage(), db: db);
    expect(find.text('XTS -12345 最小单位'), findsOneWidget);
    _expectSummary('支出', '0.00');
    expect(find.text('-123.45'), findsNothing);
    await _selectCurrency(tester, 'XTS（最小单位）');
    _expectSummary('支出', 'XTS 12345 最小单位');
    _expectSummary('结余', 'XTS -12345 最小单位');
    expect(find.text('支出 XTS 12345 最小单位'), findsOneWidget);

    await tester.tap(find.text('未知币种账单'));
    await settleProviders(tester);
    expect(_detailText('XTS -12345 最小单位'), findsOneWidget);
    expect(_detailText('XTS'), findsOneWidget);
    expect(_detailText('-¥ 123.45'), findsNothing);
    expect((await db.getAllBills()).single, before);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('320宽大字体月日摘要精确显示int64以上合计且原币行无溢出', (tester) async {
    _narrowLargeText(tester);
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _bill(db, '最大单据', amount: 9223372036854775807);
    await _bill(db, '再加一分', amount: 1);
    await pumpPage(tester, const BillsPage(), db: db);

    const total = '92,233,720,368,547,758.08';
    _expectSummary('支出', total);
    _expectSummary('结余', '-$total');
    expect(find.text('支出 $total'), findsOneWidget);
    expect(find.text('-92,233,720,368,547,758.07'), findsOneWidget);
    _expectWithinScreen(tester, find.text(total));
    _expectWithinScreen(tester, find.text('支出 $total'));
    _expectWithinScreen(tester, find.text('-92,233,720,368,547,758.07'));
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('320宽大字体跨币详情完整显示人民币及日元最大金额并可滚动', (tester) async {
    _narrowLargeText(tester);
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await _account(db, 'jpy', 'JPY');
    final bill = await _bill(
      db,
      '大额兑换',
      type: 2,
      amount: 9223372036854775807,
      toAccountId: 'jpy',
      toAccountAmount: 9223372036854775807,
    );
    await pumpPage(tester, _host(bill), db: db);
    await _openDetail(tester);

    const outgoing = '¥ 92,233,720,368,547,758.07';
    const incoming = 'JPY 9,223,372,036,854,775,807';
    expect(_detailText(outgoing), findsWidgets);
    expect(_detailText(incoming), findsOneWidget);
    final incomingText = _detailText(incoming);
    await tester.ensureVisible(incomingText);
    await settleProviders(tester);
    _expectWithinScreen(tester, incomingText);
    final viewport = tester.getRect(
      find.byKey(const ValueKey('bill-detail-scroll')),
    );
    final amountRect = tester.getRect(incomingText);
    expect(amountRect.top, greaterThanOrEqualTo(viewport.top - 0.1));
    expect(amountRect.bottom, lessThanOrEqualTo(viewport.bottom + 0.1));
    expect(find.byTooltip('关闭详情').hitTestable(), findsOneWidget);
    expect((await db.getAllBills()).single, bill);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
