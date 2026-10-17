import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/utils/report_conversion.dart';
import 'package:aa_expense_splitter/utils/report_filter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

RateQuote _quote(
  Currency base,
  String rate, {
  bool manual = false,
  bool stale = false,
}) => RateQuote(
  base: base,
  quote: Currency.cny,
  ratio: RateRatio.parse(rate),
  isManual: manual,
  isStale: stale,
  source: manual ? '手动设置' : 'Frankfurter / ECB',
  quotedAt: DateTime.utc(2026, 10, 16),
  fetchedAt: DateTime.utc(2026, 10, 16, 10, 30),
);

FrozenCnyQuotes _frozen(Map<Currency, RateQuote> quotes) =>
    FrozenCnyQuotes.capture((base, target) {
      assert(target == Currency.cny);
      return quotes[base];
    });

Bill _bill(
  String id, {
  int type = 0,
  required int amount,
  required String currency,
  String? categoryId,
  int dateMs = 100,
  bool deleted = false,
}) => mkBill(
  id,
  type: type,
  amount: amount,
  currency: currency,
  categoryId: categoryId,
  dateMs: dateMs,
  deletedAt: deleted ? 1 : null,
);

void main() {
  test('CNY账单恒等折算，整集完整且无未纳入', () {
    final quotes = _frozen({
      Currency.cny: _quote(Currency.cny, '1'),
    });
    final bills = [
      _bill('e1', amount: 1000, currency: 'CNY', categoryId: 'a'),
      _bill('i1', type: 1, amount: 250, currency: 'CNY'),
    ];
    final result = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    expect(result.complete, isTrue);
    expect(result.excludedView, isEmpty);
    expect(result.valueFor(bills[0]), BigInt.from(1000));
    expect(result.valueFor(bills[1]), BigInt.from(250));
    expect(result.sumFor(bills), BigInt.from(1250));
  });

  test('跨币种每笔只舍入一次，独立公式核对', () {
    final quotes = _frozen({
      Currency.cny: _quote(Currency.cny, '1'),
      Currency.usd: _quote(Currency.usd, '7.123456789012345678'),
      Currency.jpy: _quote(Currency.jpy, '0.04927'),
    });
    final bills = [
      _bill('u1', amount: 1000, currency: 'USD'),
      _bill('j1', amount: 5, currency: 'JPY'),
      _bill('j2', amount: 1000, currency: 'JPY'),
    ];
    final result = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    // 10.00 USD × 7.123456789012345678 = 71.2345…CNY → 7123 分（一次舍入）。
    final usdNum = BigInt.from(1000) * BigInt.parse('7123456789012345678');
    const usdDen = 1000000000000000000;
    // 独立的远离零公式：floor((2×n + d) / 2d)。
    final expectedUsd =
        (BigInt.from(2) * usdNum + BigInt.from(usdDen)) ~/
        (BigInt.from(2) * BigInt.from(usdDen));
    expect(result.valueFor(bills[0]), expectedUsd);
    expect(result.valueFor(bills[0]), BigInt.from(7123));
    // 0.05 JPY × 0.04927 = 2.4635 分 → 25（远离零）。
    expect(result.valueFor(bills[1]), BigInt.from(25));
    // 1000 JPY × 0.049265 等价半分：985300000/200000 = 4926.5 → 4927。
    final halfQuotes = _frozen({
      Currency.jpy: _quote(Currency.jpy, '0.049265'),
    });
    final half = CnyConvertedBills.convert(
      bills: [bills[2]],
      quotes: halfQuotes,
    );
    expect(half.valueFor(bills[2]), BigInt.from(4927));
  });

  test('收支与分类分区守恒，总额等于全部分区之和', () {
    final quotes = _frozen({
      Currency.cny: _quote(Currency.cny, '1'),
      Currency.usd: _quote(Currency.usd, '7'),
      Currency.jpy: _quote(Currency.jpy, '0.05'),
    });
    final bills = [
      _bill('e-a-1', amount: 100, currency: 'CNY', categoryId: 'a'),
      _bill('e-a-2', amount: 1000, currency: 'USD', categoryId: 'a'),
      _bill('e-b-1', amount: 200, currency: 'JPY', categoryId: 'b'),
      _bill('e-x-1', amount: 50, currency: 'CNY'),
      _bill('i-a-1', type: 1, amount: 300, currency: 'CNY', categoryId: 'a'),
      _bill('i-b-1', type: 1, amount: 500, currency: 'JPY', categoryId: 'b'),
    ];
    final result = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    final total = result.sumFor(bills);
    final income = bills.where((b) => b.type == 1).toList();
    final expense = bills.where((b) => b.type == 0).toList();
    expect(result.sumFor(income) + result.sumFor(expense), total);
    for (final partition in ['a', 'b', null]) {
      final subset = bills
          .where((b) => b.categoryId == partition)
          .toList();
      // sumFor 必须等于逐笔 valueFor 之和（分区复用同一逐笔值）。
      final viaSum = result.sumFor(subset);
      final viaValues = subset.fold(
        BigInt.zero,
        (sum, b) => sum + result.valueFor(b)!,
      );
      expect(viaSum, viaValues);
    }
    final categorySums = ['a', 'b', null]
        .map(
          (p) => result.sumFor(
            bills.where((b) => b.categoryId == p).toList(),
          ),
        )
        .reduce((a, b) => a + b);
    expect(categorySums, total);
    // 每笔值稳定，不随读取次数或后续汇率变化。
    expect(result.valueFor(bills[1]), result.valueFor(bills[1]));
  });

  test('缺率币种进未纳入清单并保留原币合计，其余照常折算', () {
    final quotes = _frozen({
      Currency.cny: _quote(Currency.cny, '1'),
      Currency.jpy: _quote(Currency.jpy, '0.05'),
    });
    final bills = [
      _bill('c1', amount: 100, currency: 'CNY'),
      _bill('u1', amount: 1000, currency: 'USD'),
      _bill('u2', amount: 250, currency: 'USD'),
      _bill('j1', amount: 200, currency: 'JPY'),
    ];
    final result = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    expect(result.complete, isFalse);
    expect(result.excludedView.length, 1);
    expect(result.excludedView.first.code, 'USD');
    expect(result.excludedView.first.count, 2);
    expect(result.excludedView.first.originalMinor, BigInt.from(1250));
    expect(result.valueFor(bills[0]), BigInt.from(100));
    expect(result.valueFor(bills[3]), BigInt.from(1000));
    expect(result.valueFor(bills[1]), isNull);
  });

  test('未知历史币种代码原样进未纳入清单', () {
    final quotes = _frozen({Currency.cny: _quote(Currency.cny, '1')});
    final bills = [_bill('x1', amount: 7, currency: 'BTC')];
    final result = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    expect(result.complete, isFalse);
    expect(result.excludedView.single.code, 'BTC');
    expect(result.excludedView.single.count, 1);
    expect(result.excludedView.single.originalMinor, BigInt.from(7));
  });

  test('未纳入清单按归一化币种码合并，可识别的大小写码照常折算', () {
    final missing = _frozen({Currency.cny: _quote(Currency.cny, '1')});
    final bills = [
      _bill('l1', amount: 100, currency: 'usd'),
      _bill('u1', amount: 250, currency: 'USD'),
    ];
    final excluded = CnyConvertedBills.convert(bills: bills, quotes: missing);
    expect(excluded.complete, isFalse);
    expect(excluded.excludedView.length, 1);
    expect(excluded.excludedView.single.code, 'USD');
    expect(excluded.excludedView.single.count, 2);
    expect(excluded.excludedView.single.originalMinor, BigInt.from(350));
    // 有可用报价时，历史小写码按归一化后的 USD 汇率折算。
    final withRate = _frozen({
      Currency.cny: _quote(Currency.cny, '1'),
      Currency.usd: _quote(Currency.usd, '7'),
    });
    final converted = CnyConvertedBills.convert(
      bills: bills,
      quotes: withRate,
    );
    expect(converted.complete, isTrue);
    expect(converted.valueFor(bills[0]), BigInt.from(700));
    expect(converted.valueFor(bills[1]), BigInt.from(1750));
  });

  test('过期状态如实透传，手动报价不计过期', () {
    final staleSet = _frozen({
      Currency.cny: _quote(Currency.cny, '1'),
      Currency.usd: _quote(Currency.usd, '7', stale: true),
    });
    expect(staleSet.hasStale, isTrue);
    expect(staleSet.allManual, isFalse);
    final manualSet = _frozen({
      Currency.cny: _quote(Currency.cny, '1', manual: true),
      Currency.usd: _quote(Currency.usd, '7', manual: true, stale: true),
    });
    expect(manualSet.hasStale, isFalse);
    expect(manualSet.allManual, isTrue);
  });

  test('冻结集与后续报价变化隔离，同一集合折算值不变', () {
    var current = _quote(Currency.usd, '7');
    final quotes = FrozenCnyQuotes.capture((base, target) {
      assert(target == Currency.cny);
      return base == Currency.cny ? _quote(Currency.cny, '1') : current;
    });
    final bills = [_bill('u1', amount: 1000, currency: 'USD')];
    final first = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    expect(first.valueFor(bills[0]), BigInt.from(7000));
    current = _quote(Currency.usd, '8');
    final again = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    expect(again.valueFor(bills[0]), BigInt.from(7000));
  });

  test('折算值超出int64仍保持BigInt精度', () {
    final quotes = _frozen({
      Currency.jpy: _quote(Currency.jpy, '2'),
    });
    final bills = [_bill('j1', amount: 9223372036854775807, currency: 'JPY')];
    final result = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    // JPY 0 位 → CNY 2 位：int64max × 2 × 100，已超出 int64 仍精确。
    expect(
      result.valueFor(bills[0]),
      BigInt.parse('1844674407370955161400'),
    );
    expect(result.complete, isTrue);
  });

  test('全币种筛选只选收支活账并排除转账本金与删除账', () {
    final inPeriod = DateTime(2026, 10, 17).millisecondsSinceEpoch;
    final outOfPeriod = DateTime(2026, 9, 1).millisecondsSinceEpoch;
    final bills = [
      _bill('e-cny', amount: 100, currency: 'CNY', categoryId: 'a', dateMs: inPeriod),
      _bill('e-usd', amount: 1000, currency: 'USD', categoryId: 'a', dateMs: inPeriod),
      _bill('i-jpy', type: 1, amount: 500, currency: 'JPY', dateMs: inPeriod),
      _bill('t1', type: 2, amount: 700, currency: 'CNY', dateMs: inPeriod),
      _bill('del', amount: 999, currency: 'CNY', dateMs: inPeriod, deleted: true),
      _bill('old', amount: 800, currency: 'CNY', dateMs: outOfPeriod),
    ];
    final selected = filterReportBills(
      bills: bills,
      categories: const [],
      filter: ReportFilter.allCurrencies(
        period: ReportPeriod.month(DateTime(2026, 10)),
      ),
    );
    expect(
      selected.map((b) => b.id).toSet(),
      {'e-cny', 'e-usd', 'i-jpy'},
    );
    final typed = filterReportBills(
      bills: bills,
      categories: const [],
      filter: ReportFilter.allCurrencies(
        period: ReportPeriod.month(DateTime(2026, 10)),
        type: 0,
      ),
    );
    expect(typed.map((b) => b.id).toSet(), {'e-cny', 'e-usd'});
  });

  test('R-01选择集折算：费用计入一次而转账本金不出现', () {
    final quotes = _frozen({
      Currency.cny: _quote(Currency.cny, '1'),
    });
    final bills = [
      _bill('transfer', type: 2, amount: 700, currency: 'CNY'),
      _bill('fee', amount: 200, currency: 'CNY'),
      _bill('expense', amount: 100, currency: 'CNY', categoryId: 'a'),
    ];
    final selection = filterReportBills(
      bills: bills,
      categories: const [],
      filter: ReportFilter.allCurrencies(),
    );
    expect(selection.map((b) => b.id).toSet(), {'fee', 'expense'});
    final result = CnyConvertedBills.convert(
      bills: selection,
      quotes: quotes,
    );
    expect(result.complete, isTrue);
    expect(result.sumFor(selection), BigInt.from(300));
    expect(result.valueFor(bills.first), isNull);
  });

  test('结果容器不可变，输入列表后续变化不影响已折算值', () {
    final quotes = _frozen({Currency.cny: _quote(Currency.cny, '1')});
    final bills = [_bill('c1', amount: 100, currency: 'CNY')];
    final result = CnyConvertedBills.convert(bills: bills, quotes: quotes);
    expect(
      () => result.excludedView.add(
        CnyExcludedCurrency(
          code: 'X',
          count: 1,
          originalMinor: BigInt.zero,
        ),
      ),
      throwsUnsupportedError,
    );
    bills.clear();
    expect(result.valueFor(_bill('c1', amount: 100, currency: 'CNY')),
        BigInt.from(100));
  });
}
