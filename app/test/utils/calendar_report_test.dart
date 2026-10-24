import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_service.dart';
import 'package:aa_expense_splitter/utils/calendar_report.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/utils/report.dart';
import 'package:aa_expense_splitter/utils/report_conversion.dart';

Bill _bill(
  String id,
  int amount, {
  DateTime? date,
  int? dateMs,
  int type = 0,
  String currency = 'CNY',
  String? category,
  int? accountAmount,
  int? deletedAt,
  String? feeTransferId,
  bool isAa = false,
  String? settlementId,
}) => Bill(
  id: id,
  type: type,
  amount: amount,
  currency: currency,
  accountAmount: accountAmount ?? amount,
  toAccountAmount: type == 2 ? amount : null,
  feeTransferId: feeTransferId,
  categoryId: category,
  accountId: 'cash',
  toAccountId: type == 2 ? 'bank' : null,
  dateMs: dateMs ?? (date ?? DateTime(2024, 2, 15)).millisecondsSinceEpoch,
  note: 'calendar $id',
  isAa: isAa,
  aaGroupId: isAa ? 'group-$id' : null,
  settlementId: settlementId,
  createdAt: 17,
  updatedAt: 19,
  deletedAt: deletedAt,
);

Category _category(String id, {int kind = 0, String? parent}) => Category(
  id: id,
  parentId: parent,
  name: id,
  emoji: '🍜',
  kind: kind,
  sort: 0,
  isPreset: false,
);

RateQuote _quote(
  Currency base,
  String ratio, {
  bool manual = false,
  bool stale = false,
}) => RateQuote(
  base: base,
  quote: Currency.cny,
  ratio: RateRatio.parse(ratio),
  isManual: manual,
  isStale: stale,
  source: manual ? '手动设置' : 'Frankfurter / ECB',
  quotedAt: DateTime.utc(2024, 2, 1),
  fetchedAt: DateTime.utc(2024, 2, 1, 10),
);

FrozenCnyQuotes _quotes(Map<Currency, RateQuote> values) =>
    FrozenCnyQuotes.capture((base, target) => values[base]);

CalendarReport _calendar(
  Iterable<Bill> bills, {
  DateTime? month,
  Iterable<Category> categories = const [],
  String? currency = 'CNY',
  FrozenCnyQuotes? quotes,
}) => buildCalendarReport(
  month: month ?? DateTime(2024, 2),
  bills: bills,
  categories: categories,
  currency: currency,
  quotes: quotes,
);

List<String> _ids(Iterable<Bill> bills) => bills.map((b) => b.id).toList();

void _expectConserved(CalendarReport report) {
  expect(
    report.days.fold(BigInt.zero, (sum, day) => sum + day.income),
    report.income,
  );
  expect(
    report.days.fold(BigInt.zero, (sum, day) => sum + day.expense),
    report.expense,
  );
  expect(
    report.days.fold(BigInt.zero, (sum, day) => sum + day.balance),
    report.balance,
  );
  final dailyIds = report.days.expand((day) => day.bills).map((b) => b.id);
  expect(dailyIds.length, report.bills.length);
  expect(dailyIds.toSet(), report.billIds);
  for (final day in report.days) {
    expect(day.incomeBills.length + day.expenseBills.length, day.bills.length);
    expect(
      day.includedBills.length + day.excludedBills.length,
      day.bills.length,
    );
    for (final bill in day.bills) {
      expect(day.valueFor(bill), report.valueFor(bill));
    }
  }
}

void main() {
  test('铺满本地月份：闰年、世纪规则、大小月及空日不造账', () {
    for (final sample in [
      (DateTime(2024, 2, 19, 18, 30), 29),
      (DateTime(2023, 2), 28),
      (DateTime(1900, 2), 28),
      (DateTime(2000, 2), 29),
      (DateTime(2024, 4), 30),
      (DateTime(2024, 12), 31),
    ]) {
      final report = _calendar(const [], month: sample.$1);
      expect(report.month, DateTime(sample.$1.year, sample.$1.month));
      expect(report.month.isUtc, isFalse);
      expect(report.days, hasLength(sample.$2));
      expect(report.days.first.date, report.month);
      expect(report.days.last.date.day, sample.$2);
      for (var index = 0; index < report.days.length; index++) {
        final day = report.days[index];
        expect(
          day.date,
          DateTime(report.month.year, report.month.month, index + 1),
        );
        expect(day.bills, isEmpty);
        expect(day.income, BigInt.zero);
        expect(day.expense, BigInt.zero);
        expect(day.complete, isTrue);
      }
      expect(report.bills, isEmpty);
      expect(report.balance, BigInt.zero);
      _expectConserved(report);
    }
  });

  test('月首含、次月零点不含，跨月同日与跨年不能混在一起', () {
    final start = DateTime(2024, 12).millisecondsSinceEpoch;
    final end = DateTime(2025).millisecondsSinceEpoch;
    final report = _calendar([
      _bill('previous', 999, dateMs: start - 1),
      _bill('first', 100, dateMs: start),
      _bill('last', 200, dateMs: end - 1),
      _bill('next', 999, dateMs: end),
      _bill('same-day-last-month', 999, date: DateTime(2024, 11, 15)),
      _bill('this-month-15', 300, date: DateTime(2024, 12, 15)),
      _bill('same-day-next-year', 999, date: DateTime(2025, 12, 15)),
    ], month: DateTime(2024, 12));
    expect(_ids(report.bills), ['last', 'this-month-15', 'first']);
    expect(report.period.startMs, start);
    expect(report.period.endMs, end);
    expect(report.days.first.expense, BigInt.from(100));
    expect(report.days.last.expense, BigInt.from(200));
    expect(
      report.dayFor(DateTime(2024, 12, 15, 20))!.expense,
      BigInt.from(300),
    );
    expect(report.dayFor(DateTime(2024, 11, 15)), isNull);
    expect(report.dayFor(DateTime(2025, 12, 15)), isNull);
    expect(report.expense, BigInt.from(600));
    _expectConserved(report);
  });

  test('交易时间戳按本地年月日归属，不使用UTC日期或固定24小时桶', () {
    final instant = DateTime.utc(2024, 2, 29, 19, 30);
    final local = instant.toLocal();
    final report = _calendar([
      _bill('instant', 123, dateMs: instant.millisecondsSinceEpoch),
    ], month: DateTime(local.year, local.month));
    expect(report.dayFor(local)!.billIds, {'instant'});
    expect(
      report.dayFor(local)!.date,
      DateTime(local.year, local.month, local.day),
    );
    final dates = report.days.map((day) => day.date).toList();
    expect(dates.toSet(), hasLength(dates.length));
    _expectConserved(report);
  });

  test('复用R01：排除本金/调账/删除/内部收入，保留费用、旧内部支出及AA结算', () {
    final categories = [_category('internal', kind: 2), _category('food')];
    final bills = [
      _bill('transfer', 1000, type: 2),
      _bill('fee', 1, feeTransferId: 'transfer'),
      _bill('adjustment', 2000, type: 3),
      _bill('deleted', 3000, deletedAt: 1),
      _bill('cancelled-fee', 9, feeTransferId: 'old-transfer', deletedAt: 1),
      _bill('internal-income', 4000, type: 1, category: 'internal'),
      _bill('old-internal-expense', 7, category: 'internal'),
      _bill('aa-full', 100, category: 'food', isAa: true),
      _bill('settlement-income', 50, type: 1, settlementId: 'settlement'),
      _bill('settlement-expense', 30, settlementId: 'settlement'),
      _bill('unknown-category', 3, category: 'missing'),
    ];
    final report = _calendar(bills, categories: categories);
    final shared = buildReport(
      bills: bills,
      categories: categories,
      filter: ReportFilter(
        period: ReportPeriod.month(DateTime(2024, 2)),
        currency: 'CNY',
      ),
    );
    expect(_ids(report.bills), _ids(shared.bills));
    expect(report.billIds, {
      'fee',
      'old-internal-expense',
      'aa-full',
      'settlement-income',
      'settlement-expense',
      'unknown-category',
    });
    expect(report.expense, BigInt.from(141));
    expect(report.income, BigInt.from(50));
    expect(report.balance, BigInt.from(-91));
    expect(report.days[14].expense, shared.expense);
    expect(report.days[14].income, shared.income);
    _expectConserved(report);
  });

  test('原币精确隔离，金额取交易额而非账户实际额，JPY不加上其他币种', () {
    final bills = [
      _bill('jpy-expense', 101, currency: 'JPY', accountAmount: 5),
      _bill('jpy-income', 150, type: 1, currency: 'JPY', accountAmount: 7),
      _bill('cny', 999, currency: 'CNY'),
      _bill('usd', 999, currency: 'USD'),
      _bill('lower-jpy', 999, currency: 'jpy'),
    ];
    final report = _calendar(bills, currency: 'JPY');
    expect(report.isConverted, isFalse);
    expect(report.currency, 'JPY');
    expect(report.quotes, isNull);
    expect(report.converted, isNull);
    expect(report.expense, BigInt.from(101));
    expect(report.income, BigInt.from(150));
    expect(report.balance, BigInt.from(49));
    expect(report.billIds, {'jpy-expense', 'jpy-income'});
    expect(report.complete, isTrue);
    expect(report.excluded, isEmpty);
    _expectConserved(report);
  });

  test('原币日/月BigInt聚合超过int64仍精确，结余不溢出', () {
    const maximum = 9223372036854775807;
    final report = _calendar([
      _bill('expense-one', maximum, date: DateTime(2024, 2, 1)),
      _bill('expense-two', maximum, date: DateTime(2024, 2, 1)),
      _bill('expense-last', 1, date: DateTime(2024, 2, 29)),
      _bill('income-one', maximum, type: 1, date: DateTime(2024, 2, 29)),
      _bill('income-two', 2, type: 1, date: DateTime(2024, 2, 29)),
    ]);
    expect(report.days.first.expense, BigInt.parse('18446744073709551614'));
    expect(report.days.last.income, BigInt.parse('9223372036854775809'));
    expect(report.expense, BigInt.parse('18446744073709551615'));
    expect(report.balance, BigInt.parse('-9223372036854775806'));
    _expectConserved(report);
  });

  test('折算逐笔半分舍入只做一次：日/月/当天三种明细使用同一值', () {
    final report = _calendar(
      [
        _bill('usd-a', 1, currency: 'USD', date: DateTime(2024, 2, 1)),
        _bill('usd-b', 1, currency: 'USD', date: DateTime(2024, 2, 1)),
        _bill('jpy', 1, currency: 'JPY', date: DateTime(2024, 2, 29)),
        _bill(
          'income',
          1,
          type: 1,
          currency: 'USD',
          date: DateTime(2024, 2, 29),
        ),
      ],
      currency: null,
      quotes: _quotes({
        Currency.usd: _quote(Currency.usd, '0.5'),
        Currency.jpy: _quote(Currency.jpy, '0.005'),
      }),
    );
    expect(report.isConverted, isTrue);
    expect(report.currency, 'CNY');
    expect(report.days.first.expense, BigInt.from(2));
    expect(report.days.last.expense, BigInt.one);
    expect(report.days.last.income, BigInt.one);
    expect(report.expense, BigInt.from(3));
    expect(report.income, BigInt.one);
    expect(report.balance, BigInt.from(-2));
    expect(_ids(report.days.last.incomeBills), ['income']);
    expect(_ids(report.days.last.expenseBills), ['jpy']);
    for (final bill in report.bills) {
      expect(report.valueFor(bill), report.converted!.valueFor(bill));
    }
    _expectConserved(report);
  });

  test('缺率和未知币保留在每日选集，日与月标部分合计，不伪装成完整零值', () {
    final bills = [
      _bill('cny', 100, date: DateTime(2024, 2, 1)),
      _bill('usd', 250, currency: 'USD', date: DateTime(2024, 2, 1)),
      _bill(
        'lower-usd',
        50,
        type: 1,
        currency: 'usd',
        date: DateTime(2024, 2, 2),
      ),
      _bill('unknown', 7, currency: 'BTC', date: DateTime(2024, 2, 2)),
    ];
    final report = _calendar(
      bills,
      currency: null,
      quotes: _quotes({Currency.cny: _quote(Currency.cny, '1')}),
    );
    expect(report.complete, isFalse);
    expect(report.expense, BigInt.from(100));
    expect(report.income, BigInt.zero);
    expect(report.includedBills.single.id, 'cny');
    expect(report.excludedBills.map((b) => b.id).toSet(), {
      'usd',
      'lower-usd',
      'unknown',
    });
    expect(report.excluded.map((item) => item.code).toSet(), {'USD', 'BTC'});
    final usd = report.excluded.singleWhere((item) => item.code == 'USD');
    expect(usd.count, 2);
    expect(usd.originalMinor, BigInt.from(300));
    final first = report.days.first;
    expect(first.billIds, {'cny', 'usd'});
    expect(first.complete, isFalse);
    expect(first.expense, BigInt.from(100));
    final second = report.days[1];
    expect(second.billIds, {'lower-usd', 'unknown'});
    expect(second.incomeBills.single.id, 'lower-usd');
    expect(second.complete, isFalse);
    expect(second.income, BigInt.zero);
    expect(second.expense, BigInt.zero);
    expect(report.days[2].complete, isTrue);
    expect(first.valueFor(bills[1]), isNull);
    // A row elsewhere in the same month is not a member of this day.
    expect(first.valueFor(bills[2]), isNull);
    _expectConserved(report);
  });

  test('全月无可用汇率时保留交易并标不完整，未选入的外月不污染缺率清单', () {
    final report = _calendar(
      [
        _bill('missing-cny', 10),
        _bill('missing-usd', 20, currency: 'USD'),
        _bill('outside', 30, currency: 'BTC', date: DateTime(2024, 3, 15)),
      ],
      currency: null,
      quotes: _quotes({}),
    );
    expect(report.bills, hasLength(2));
    expect(report.complete, isFalse);
    expect(report.expense, BigInt.zero);
    expect(report.excluded.map((item) => item.code).toSet(), {'CNY', 'USD'});
    expect(report.dayFor(DateTime(2024, 2, 15))!.complete, isFalse);
    _expectConserved(report);
  });

  test('冻结报价只捕获一次，原始金额/来源时间/手动与过期状态保留', () {
    var calls = 0;
    var usd = _quote(Currency.usd, '7', manual: true);
    final staleJpy = _quote(Currency.jpy, '0.05', stale: true);
    final quotes = FrozenCnyQuotes.capture((base, target) {
      calls++;
      return switch (base) {
        Currency.usd => usd,
        Currency.jpy => staleJpy,
        _ => null,
      };
    });
    expect(calls, Currency.values.length);
    final bills = [
      _bill('usd', 100, currency: 'USD'),
      _bill('jpy', 10, currency: 'JPY'),
    ];
    final report = _calendar(bills, currency: null, quotes: quotes);
    usd = _quote(Currency.usd, '8');
    expect(report.quotes, same(quotes));
    expect(report.quotes!.quoteFor(Currency.usd)!.isManual, isTrue);
    expect(report.quotes!.quoteFor(Currency.usd)!.source, '手动设置');
    expect(
      report.quotes!.quoteFor(Currency.usd)!.fetchedAt,
      DateTime.utc(2024, 2, 1, 10),
    );
    expect(report.quotes!.hasStale, isTrue);
    expect(report.expense, BigInt.from(750));
    expect(report.days[14].expense, BigInt.from(750));
    expect(calls, Currency.values.length);
    final refreshed = _calendar(
      bills,
      currency: null,
      quotes: _quotes({Currency.usd: usd, Currency.jpy: staleJpy}),
    );
    expect(refreshed.expense, BigInt.from(850));
    expect(report.expense, BigInt.from(750));
    expect(bills.first.amount, 100);
    _expectConserved(report);
  });

  test('当天全部/收入/支出排序稳定、不可修改，外部输入变化不改旧快照', () {
    final bills = [
      _bill('same-b', 20, date: DateTime(2024, 2, 15, 10)),
      _bill('income', 40, type: 1, date: DateTime(2024, 2, 15, 11)),
      _bill('same-a', 10, date: DateTime(2024, 2, 15, 10)),
    ];
    final categories = [_category('food')];
    final before = bills.map((bill) => bill.toJson()).toList();
    final report = _calendar(bills, categories: categories);
    final day = report.days[14];
    expect(_ids(day.bills), ['income', 'same-a', 'same-b']);
    expect(_ids(day.incomeBills), ['income']);
    expect(_ids(day.expenseBills), ['same-a', 'same-b']);
    expect(bills.map((bill) => bill.toJson()).toList(), before);
    bills.clear();
    categories.clear();
    expect(report.expense, BigInt.from(30));
    expect(day.balance, BigInt.from(10));
    expect(() => report.days.clear(), throwsUnsupportedError);
    expect(() => report.bills.clear(), throwsUnsupportedError);
    expect(() => report.billIds.clear(), throwsUnsupportedError);
    expect(() => day.bills.clear(), throwsUnsupportedError);
    expect(() => day.incomeBills.clear(), throwsUnsupportedError);
    expect(() => day.expenseBills.clear(), throwsUnsupportedError);
    expect(() => day.includedBills.clear(), throwsUnsupportedError);
    expect(() => day.excludedBills.clear(), throwsUnsupportedError);
    expect(() => day.billIds.clear(), throwsUnsupportedError);
    _expectConserved(report);
  });

  test('重建后编辑日期/金额、删除和分类口径更新，旧月日快照保持原值', () {
    final oldBill = _bill(
      'editable',
      100,
      category: 'changing',
      date: DateTime(2024, 2, 1),
    );
    final income = _bill('income', 30, type: 1, category: 'changing');
    final original = _calendar(
      [oldBill, income],
      categories: [_category('changing')],
    );
    final edited = _calendar(
      [
        oldBill.copyWith(
          amount: 120,
          accountAmount: 120,
          dateMs: DateTime(2024, 2, 29).millisecondsSinceEpoch,
        ),
        income,
      ],
      categories: [_category('changing', kind: 2)],
    );
    expect(original.days.first.expense, BigInt.from(100));
    expect(original.days.last.expense, BigInt.zero);
    expect(original.income, BigInt.from(30));
    expect(edited.days.first.expense, BigInt.zero);
    expect(edited.days.last.expense, BigInt.from(120));
    expect(edited.income, BigInt.zero);
    final deleted = _calendar([
      _bill('editable', 120, deletedAt: 1, date: DateTime(2024, 2, 29)),
    ]);
    expect(deleted.bills, isEmpty);
    expect(edited.expense, BigInt.from(120));
    _expectConserved(original);
    _expectConserved(edited);
    _expectConserved(deleted);
  });

  test('总览必须显式提供冻结报价，不能回退为混币原始合计', () {
    expect(
      () => _calendar([_bill('usd', 100, currency: 'USD')], currency: null),
      throwsArgumentError,
    );
  });
}
