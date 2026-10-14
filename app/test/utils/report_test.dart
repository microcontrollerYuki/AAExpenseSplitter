import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/utils/report.dart';

Category _category(
  String id, {
  String? parent,
  int kind = 0,
  int sort = 0,
  String? name,
}) => Category(
  id: id,
  parentId: parent,
  name: name ?? id,
  emoji: '🍜',
  kind: kind,
  sort: sort,
  isPreset: false,
);

Bill _bill(
  String id,
  int amount, {
  String? category,
  int type = 0,
  String currency = 'CNY',
  DateTime? date,
  int? dateMs,
  int? accountAmount,
  int? deletedAt,
  bool isAa = false,
  String? settlementId,
}) => Bill(
  id: id,
  type: type,
  amount: amount,
  currency: currency,
  accountAmount: accountAmount ?? amount,
  toAccountAmount: type == 2 ? amount : null,
  categoryId: category,
  accountId: 'cash',
  toAccountId: type == 2 ? 'bank' : null,
  dateMs: dateMs ?? (date ?? DateTime(2024, 2, 15)).millisecondsSinceEpoch,
  note: '报表测试 $id',
  isAa: isAa,
  aaGroupId: isAa ? 'group-$id' : null,
  settlementId: settlementId,
  createdAt: 17,
  updatedAt: 19,
  deletedAt: deletedAt,
);

List<String> _ids(Iterable<Bill> bills) => bills.map((b) => b.id).toList();

ReportResult _report(
  Iterable<Bill> bills, {
  Iterable<Category> categories = const [],
  ReportPeriod? period,
  String currency = 'CNY',
  int? type,
  ReportCategoryFilter category = const ReportCategoryFilter.all(),
}) => buildReport(
  bills: bills,
  categories: categories,
  filter: ReportFilter(
    period: period,
    currency: currency,
    type: type,
    category: category,
  ),
);

void _expectConserved(ReportResult result) {
  expect(
    result.expenseBills.fold(
      BigInt.zero,
      (sum, b) => sum + BigInt.from(b.amount),
    ),
    result.expense,
  );
  expect(
    result.incomeBills.fold(
      BigInt.zero,
      (sum, b) => sum + BigInt.from(b.amount),
    ),
    result.income,
  );
  expect(result.balance, result.income - result.expense);
  expect(result.expenseStats.total, result.expense);
  expect(result.incomeStats.total, result.income);
  expect(
    result.expenseStats.groups.fold(BigInt.zero, (sum, g) => sum + g.amount),
    result.expense,
  );
  expect(
    result.incomeStats.groups.fold(BigInt.zero, (sum, g) => sum + g.amount),
    result.income,
  );
}

void main() {
  group('ReportPeriod 本地日历和左闭右开边界', () {
    test('原始毫秒区间包括起点与末毫秒，排除前一毫秒和终点', () {
      final period = ReportPeriod(startMs: 1000, endMs: 2000);
      expect(period.contains(999), isFalse);
      expect(period.contains(1000), isTrue);
      expect(period.contains(1999), isTrue);
      expect(period.contains(2000), isFalse);
      expect(period.start.millisecondsSinceEpoch, 1000);
      expect(period.end.millisecondsSinceEpoch, 2000);
      expect(period.start.isUtc, isFalse);
      expect(period.end.isUtc, isFalse);
    });

    test('零长和反向毫秒区间拒绝', () {
      for (final end in [999, 1000]) {
        expect(
          () => ReportPeriod(startMs: 1000, endMs: end),
          throwsArgumentError,
        );
      }
    });

    test('月工厂忽略日时分并使用本地月首', () {
      final period = ReportPeriod.month(
        DateTime(2024, 10, 14, 23, 59, 59, 999),
      );
      expect(period.start, DateTime(2024, 10, 1));
      expect(period.end, DateTime(2024, 11, 1));
    });

    test('十二月终点跨年，不把次年一月计入', () {
      final period = ReportPeriod.month(DateTime(2023, 12, 31));
      expect(period.start, DateTime(2023, 12, 1));
      expect(period.end, DateTime(2024, 1, 1));
      expect(
        period.contains(
          DateTime(2023, 12, 31, 23, 59, 59, 999).millisecondsSinceEpoch,
        ),
        isTrue,
      );
      expect(
        period.contains(DateTime(2024, 1, 1).millisecondsSinceEpoch),
        isFalse,
      );
    });

    test('闰年二月包括29日，非闰年二月结束于3月1日', () {
      final leap = ReportPeriod.month(DateTime(2024, 2));
      final common = ReportPeriod.month(DateTime(2023, 2));
      expect(leap.start, DateTime(2024, 2, 1));
      expect(leap.end, DateTime(2024, 3, 1));
      expect(
        leap.contains(
          DateTime(2024, 2, 29, 23, 59, 59, 999).millisecondsSinceEpoch,
        ),
        isTrue,
      );
      expect(common.start, DateTime(2023, 2, 1));
      expect(common.end, DateTime(2023, 3, 1));
    });

    test('年工厂按年首至下一年年首包括闰日与年末', () {
      for (final year in [2023, 2024]) {
        final period = ReportPeriod.year(year);
        expect(period.start, DateTime(year, 1, 1));
        expect(period.end, DateTime(year + 1, 1, 1));
        expect(
          period.contains(
            DateTime(year, 12, 31, 23, 59, 59, 999).millisecondsSinceEpoch,
          ),
          isTrue,
        );
        expect(
          period.contains(DateTime(year + 1, 1, 1).millisecondsSinceEpoch),
          isFalse,
        );
      }
      expect(
        ReportPeriod.year(2024)
            .contains(DateTime(2024, 2, 29).millisecondsSinceEpoch),
        isTrue,
      );
    });

    test('自定义起止日都包含，跨闰日以次日零点为终点', () {
      final period = ReportPeriod.inclusiveDays(
        DateTime(2024, 2, 28, 17, 30),
        DateTime(2024, 3, 1, 1, 20),
      );
      expect(period.start, DateTime(2024, 2, 28));
      expect(period.end, DateTime(2024, 3, 2));
      expect(
        period.contains(DateTime(2024, 2, 29, 12).millisecondsSinceEpoch),
        isTrue,
      );
      expect(
        period.contains(
          DateTime(2024, 3, 1, 23, 59, 59, 999).millisecondsSinceEpoch,
        ),
        isTrue,
      );
      expect(
        period.contains(DateTime(2024, 3, 2).millisecondsSinceEpoch),
        isFalse,
      );
    });

    test('同一天晚时起早时止仍是一个完整日，年末终点跨年', () {
      final period = ReportPeriod.inclusiveDays(
        DateTime(2024, 12, 31, 23),
        DateTime(2024, 12, 31, 1),
      );
      expect(period.start, DateTime(2024, 12, 31));
      expect(period.end, DateTime(2025, 1, 1));
    });

    test('自定义真正反向日期拒绝，不悄悄交换起止日期', () {
      expect(
        () => ReportPeriod.inclusiveDays(
          DateTime(2024, 3, 1),
          DateTime(2024, 2, 29, 23),
        ),
        throwsArgumentError,
      );
    });

    test('UTC输入按其年月日作为本地日历字段，不转换瞬时时区', () {
      final month = ReportPeriod.month(DateTime.utc(2024, 2, 29, 23));
      final days = ReportPeriod.inclusiveDays(
        DateTime.utc(2024, 12, 31, 23),
        DateTime.utc(2025, 1, 1, 23),
      );
      expect(month.start, DateTime(2024, 2, 1));
      expect(month.end, DateTime(2024, 3, 1));
      expect(month.start.isUtc, isFalse);
      expect(days.start, DateTime(2024, 12, 31));
      expect(days.end, DateTime(2025, 1, 2));
    });
  });

  group('统一账单集合及原币收支口径', () {
    final categories = [
      _category('expense'),
      _category('income', kind: 1),
      _category('internal', kind: 2),
      _category('bad-internal-child', kind: 2, parent: 'expense'),
    ];
    final mixedBills = [
      _bill('aa-expense', 1000, category: 'expense', isAa: true),
      _bill(
        'settlement-expense',
        200,
        category: 'expense',
        settlementId: 'settlement',
      ),
      _bill('historical-internal-expense', 400, category: 'internal'),
      _bill('normal-income', 600, type: 1, category: 'income'),
      _bill('aa-normal-income', 100, type: 1, category: 'income', isAa: true),
      _bill(
        'settlement-income',
        700,
        type: 1,
        category: 'income',
        settlementId: 'settlement',
      ),
      _bill('internal-income', 2000, type: 1, category: 'internal', isAa: true),
      _bill(
        'bad-internal-income',
        3000,
        type: 1,
        category: 'bad-internal-child',
      ),
      _bill('transfer', 8000, type: 2),
      _bill('adjustment-up', 7000, type: 3),
      _bill('adjustment-down', -7000, type: 3),
      _bill('future-type', 9000, type: 4),
      _bill('deleted-expense', 5000, category: 'expense', deletedAt: 1),
      _bill('deleted-income', 6000, type: 1, category: 'income', deletedAt: 1),
    ];

    test('全部收支保留真实AA与结算收支，仅排内部收入转账调账和软删除', () {
      final result = _report(mixedBills, categories: categories);
      expect(result.expense, BigInt.from(1600));
      expect(result.income, BigInt.from(1400));
      expect(result.balance, BigInt.from(-200));
      expect(_ids(result.bills).toSet(), {
        'aa-expense',
        'settlement-expense',
        'historical-internal-expense',
        'normal-income',
        'aa-normal-income',
        'settlement-income',
      });
      _expectConserved(result);
    });

    for (final type in [0, 1]) {
      test('类型$type筛选同时约束明细总额和分类，不携带另一类型金额', () {
        final result = _report(mixedBills, categories: categories, type: type);
        expect(result.bills.every((b) => b.type == type), isTrue);
        expect(result.bills, hasLength(3));
        expect(result.expense, BigInt.from(type == 0 ? 1600 : 0));
        expect(result.income, BigInt.from(type == 1 ? 1400 : 0));
        expect(
          type == 0 ? result.incomeStats.groups : result.expenseStats.groups,
          isEmpty,
        );
        _expectConserved(result);
      });
    }

    test('收入的null和失效分类继续算收入并归入未分类', () {
      final result = _report(
        [
          _bill('null', 123, type: 1),
          _bill('missing', 456, type: 1, category: 'missing'),
          _bill('internal', 9999, type: 1, category: 'internal'),
        ],
        categories: categories,
        type: 1,
      );
      expect(_ids(result.bills), ['missing', 'null']);
      expect(result.income, BigInt.from(579));
      expect(result.incomeStats.groups.single.category, isNull);
      expect(result.incomeStats.groups.single.amount, BigInt.from(579));
      _expectConserved(result);
    });

    test('实际账户扣款和入账额不替代报表的交易原币金额', () {
      final bills = [
        _bill('usd-expense', 1000, currency: 'USD', accountAmount: 7200),
        _bill('usd-income', 250, type: 1, currency: 'USD', accountAmount: 1800),
        _bill('cny-expense', 29),
        _bill('jpy-expense', 1531, currency: 'JPY', accountAmount: 71),
      ];
      final usd = _report(bills, currency: 'USD');
      expect(usd.expense, BigInt.from(1000));
      expect(usd.income, BigInt.from(250));
      expect(usd.balance, BigInt.from(-750));
      expect(_ids(usd.bills), ['usd-expense', 'usd-income']);
      final cny = _report(bills);
      expect(cny.expense, BigInt.from(29));
      expect(cny.income, BigInt.zero);
      expect(_report(bills, currency: 'JPY').expense, BigInt.from(1531));
      _expectConserved(usd);
      _expectConserved(cny);
    });

    test('六币种和未知空白历史代码严格隔离，不规范化或默认人民币', () {
      final amounts = <String, int>{
        'CNY': 101,
        'USD': 202,
        'HKD': 303,
        'EUR': 404,
        'JPY': 505,
        'GBP': 606,
        'XTS': 707,
        '': 808,
        ' usd ': 909,
        'usd': 1001,
      };
      final bills = [
        for (final entry in amounts.entries)
          _bill('bill-${entry.value}', entry.value, currency: entry.key),
      ];
      for (final entry in amounts.entries) {
        final result = _report(bills, currency: entry.key);
        expect(result.expense, BigInt.from(entry.value), reason: entry.key);
        expect(result.bills.single.currency, entry.key);
        _expectConserved(result);
      }
      expect(_report(bills, currency: 'CAD').bills, isEmpty);
    });

    test('实际账单毫秒筛选左闭右开，首末毫秒计入且起点前和终点不计', () {
      final period = ReportPeriod.month(DateTime(2024, 2));
      final result = _report([
        _bill('before', 10000, dateMs: period.startMs - 1),
        _bill('start', 123, dateMs: period.startMs),
        _bill('last', 456, dateMs: period.endMs - 1),
        _bill('end', 20000, dateMs: period.endMs),
      ], period: period);
      expect(_ids(result.bills), ['last', 'start']);
      expect(result.expense, BigInt.from(579));
      _expectConserved(result);
    });

    test('跨年自定义集合只包括所选两日，与其他币种类型排除同时生效', () {
      final result = _report(
        [
          _bill('before', 10000, date: DateTime(2023, 12, 30, 23, 59, 59, 999)),
          _bill('december', 29, date: DateTime(2023, 12, 31)),
          _bill('january', 31, date: DateTime(2024, 1, 1, 23, 59, 59, 999)),
          _bill('after', 20000, date: DateTime(2024, 1, 2)),
          _bill('usd', 30000, date: DateTime(2024, 1, 1), currency: 'USD'),
          _bill('transfer', 40000, date: DateTime(2024, 1, 1), type: 2),
          _bill('income', 50000, date: DateTime(2024, 1, 1), type: 1),
        ],
        period: ReportPeriod.inclusiveDays(
          DateTime(2023, 12, 31),
          DateTime(2024, 1, 1),
        ),
        type: 0,
      );
      expect(_ids(result.bills), ['january', 'december']);
      expect(result.expense, BigInt.from(60));
      expect(result.income, BigInt.zero);
      _expectConserved(result);
    });

    test('没有日期范围时保留所有日期，明确空结果所有总额均为零', () {
      final result = _report([
        _bill('old', 29, date: DateTime(2000, 1, 1)),
        _bill('new', 31, date: DateTime(2100, 12, 31)),
      ]);
      expect(_ids(result.bills), ['new', 'old']);
      expect(result.expense, BigInt.from(60));
      final empty = _report(const [], categories: categories);
      expect(empty.bills, isEmpty);
      expect(empty.incomeBills, isEmpty);
      expect(empty.expenseBills, isEmpty);
      expect(empty.income, BigInt.zero);
      expect(empty.expense, BigInt.zero);
      expect(empty.balance, BigInt.zero);
      expect(empty.incomeStats.groups, isEmpty);
      expect(empty.expenseStats.groups, isEmpty);
    });

    test('仅支持全部或收入支出筛选，非法类型不会产生半合法空报表', () {
      for (final type in [-1, 2, 3, 4]) {
        expect(
          () => ReportFilter(currency: 'CNY', type: type),
          throwsArgumentError,
        );
      }
      final result = _report(mixedBills, categories: categories);
      expect(
        () => result.categoryBills(const ReportCategoryFilter.all(), type: 2),
        throwsArgumentError,
      );
    });

    test('公开filter与report使用完全相同的真实账单集合', () {
      final filter = ReportFilter(
        period: ReportPeriod.month(DateTime(2024, 2)),
        currency: 'CNY',
        type: 1,
        category: const ReportCategoryFilter.exact('income'),
      );
      final selected = filterReportBills(
        bills: mixedBills,
        categories: categories,
        filter: filter,
      );
      final result = buildReport(
        bills: mixedBills,
        categories: categories,
        filter: filter,
      );
      expect(_ids(selected), [
        'aa-normal-income',
        'normal-income',
        'settlement-income',
      ]);
      expect(result.bills, selected);
      expect(identical(result.filter, filter), isTrue);
      expect(result.income, BigInt.from(1400));
      expect(() => selected.clear(), throwsUnsupportedError);
    });
  });

  group('分类筛选与图项明细集合一致', () {
    final categories = [
      _category('food'),
      _category('lunch', parent: 'food'),
      _category('dinner', parent: 'food'),
      _category('other'),
    ];
    final bills = [
      _bill('direct', 1000, category: 'food'),
      _bill('lunch-a', 800, category: 'lunch'),
      _bill('lunch-b', 1200, category: 'lunch'),
      _bill('dinner', 3000, category: 'dinner'),
      _bill('other', 4000, category: 'other'),
      _bill('null', 100),
      _bill('missing', 200, category: 'missing'),
      _bill('empty', 300, category: ''),
    ];

    test('一级筛选包括直属与二级，金额60且各账单只出现一次', () {
      final result = _report(
        bills,
        categories: categories,
        category: const ReportCategoryFilter.root('food'),
      );
      expect(_ids(result.bills).toSet(), {
        'direct',
        'lunch-a',
        'lunch-b',
        'dinner',
      });
      expect(result.bills, hasLength(4));
      expect(result.expense, BigInt.from(6000));
      final group = result.expenseStats.groups.single;
      expect(group.category!.id, 'food');
      expect(group.amount, BigInt.from(6000));
      expect(group.directAmount, BigInt.from(1000));
      expect(group.children.map((c) => c.category.id), ['dinner', 'lunch']);
      expect(group.children.map((c) => c.amount), [
        BigInt.from(3000),
        BigInt.from(2000),
      ]);
      _expectConserved(result);
    });

    test('未细分只选一级直属，不将子分类账单重复计入', () {
      final result = _report(
        bills,
        categories: categories,
        category: const ReportCategoryFilter.direct('food'),
      );
      expect(_ids(result.bills), ['direct']);
      expect(result.expense, BigInt.from(1000));
      expect(result.expenseStats.groups.single.directAmount, BigInt.from(1000));
      expect(result.expenseStats.groups.single.children, isEmpty);
    });

    test('二级精确筛选只选自身两条，一级精确筛选仅直属', () {
      final lunch = _report(
        bills,
        categories: categories,
        category: const ReportCategoryFilter.exact('lunch'),
      );
      expect(_ids(lunch.bills), ['lunch-a', 'lunch-b']);
      expect(lunch.expense, BigInt.from(2000));
      expect(lunch.expenseStats.groups.single.category!.id, 'food');
      expect(
        lunch.expenseStats.groups.single.children.single.category.id,
        'lunch',
      );
      final rootExact = _report(
        bills,
        categories: categories,
        category: const ReportCategoryFilter.exact('food'),
      );
      expect(_ids(rootExact.bills), ['direct']);
      expect(rootExact.expense, BigInt.from(1000));
    });

    test('未分类显式合并null失效和空ID，不吞有效分类', () {
      final result = _report(
        bills,
        categories: categories,
        category: const ReportCategoryFilter.uncategorized(),
      );
      expect(_ids(result.bills), ['empty', 'missing', 'null']);
      expect(result.expense, BigInt.from(600));
      expect(result.expenseStats.groups.single.category, isNull);
      expect(result.expenseStats.groups.single.directAmount, BigInt.from(600));
      _expectConserved(result);
    });

    test('未知具体分类必须为空，不能误映射到未分类；二级不是一级直属', () {
      for (final category in [
        const ReportCategoryFilter.root('missing'),
        const ReportCategoryFilter.direct('missing'),
        const ReportCategoryFilter.exact('missing'),
        const ReportCategoryFilter.exact(''),
        const ReportCategoryFilter.direct('lunch'),
      ]) {
        final result = _report(
          bills,
          categories: categories,
          category: category,
        );
        expect(result.bills, isEmpty);
        expect(result.expense, BigInt.zero);
      }
    });

    test('精确ID集合只包含指定分类，不扩展后代，重复和未知ID不重复金额', () {
      final selected = ReportCategoryFilter.exactIds([
        'food',
        'lunch',
        'lunch',
        'missing',
      ]);
      final result = _report(bills, categories: categories, category: selected);
      expect(_ids(result.bills), ['direct', 'lunch-a', 'lunch-b']);
      expect(result.expense, BigInt.from(3000));
      expect(
        _report(
          bills,
          categories: categories,
          category: ReportCategoryFilter.exactIds(const []),
        ).bills,
        isEmpty,
      );
      _expectConserved(result);
    });

    test('图项明细总额等于对应一级直属及二级金额，可按相同集合交集', () {
      final result = _report(bills, categories: categories);
      for (final group in result.expenseStats.groups) {
        final filter = group.category == null
            ? const ReportCategoryFilter.uncategorized()
            : ReportCategoryFilter.root(group.category!.id);
        final details = result.categoryBills(filter, type: 0);
        expect(
          details.fold(BigInt.zero, (sum, b) => sum + BigInt.from(b.amount)),
          group.amount,
        );
        if (group.category != null) {
          final direct = result.categoryBills(
            ReportCategoryFilter.direct(group.category!.id),
            type: 0,
          );
          expect(
            direct.fold(BigInt.zero, (sum, b) => sum + BigInt.from(b.amount)),
            group.directAmount,
          );
        }
        for (final child in group.children) {
          final details = result.categoryBills(
            ReportCategoryFilter.exact(child.category.id),
            type: 0,
          );
          expect(
            details.fold(BigInt.zero, (sum, b) => sum + BigInt.from(b.amount)),
            child.amount,
          );
        }
      }
    });

    test('在已有筛选结果查看分类或另一类型不会扩大原区间币种类型集合', () {
      final input = [
        ...bills,
        _bill('old-food', 50000, category: 'food', date: DateTime(2024, 1, 31)),
        _bill('usd-food', 60000, category: 'food', currency: 'USD'),
        _bill('food-income', 70000, category: 'food', type: 1),
      ];
      final result = _report(
        input,
        categories: categories,
        period: ReportPeriod.month(DateTime(2024, 2)),
        type: 0,
        category: const ReportCategoryFilter.root('food'),
      );
      expect(
        result.categoryBills(const ReportCategoryFilter.root('other')),
        isEmpty,
      );
      expect(
        result.categoryBills(const ReportCategoryFilter.all(), type: 1),
        isEmpty,
      );
      expect(
        _ids(result.categoryBills(const ReportCategoryFilter.exact('lunch'))),
        ['lunch-a', 'lunch-b'],
      );
      expect(result.expense, BigInt.from(6000));
    });

    test('异常孤儿跨kind自环双环及三级各视作独立根，明细不递归或丢失', () {
      final malformed = [
        _category('root'),
        _category('child', parent: 'root'),
        _category('orphan', parent: 'missing'),
        _category('cross', parent: 'root', kind: 1),
        _category('self', parent: 'self'),
        _category('cycle-a', parent: 'cycle-b'),
        _category('cycle-b', parent: 'cycle-a'),
        _category('third', parent: 'child'),
      ];
      final input = [
        for (var i = 0; i < malformed.length; i++)
          _bill(
            'bill-${malformed[i].id}',
            (i + 1) * 100,
            category: malformed[i].id,
          ),
      ];
      final result = _report(input, categories: malformed);
      expect(result.expense, BigInt.from(3600));
      expect(result.expenseStats.groups, hasLength(7));
      expect(
        _ids(result.categoryBills(const ReportCategoryFilter.root('root'))),
        ['bill-child', 'bill-root'],
      );
      for (final id in [
        'orphan',
        'cross',
        'self',
        'cycle-a',
        'cycle-b',
        'third',
      ]) {
        expect(_ids(result.categoryBills(ReportCategoryFilter.root(id))), [
          'bill-$id',
        ]);
        expect(_ids(result.categoryBills(ReportCategoryFilter.direct(id))), [
          'bill-$id',
        ]);
      }
      _expectConserved(result);
    });

    test('历史类型与分类kind不匹配仍使用合法分类父子，不凭kind丢掉真实收支', () {
      final metadata = [
        _category('expense'),
        _category('expense-child', parent: 'expense'),
        _category('income', kind: 1),
        _category('income-child', kind: 1, parent: 'income'),
      ];
      final result = _report([
        _bill('old-expense', 123, category: 'income-child'),
        _bill('old-income', 456, type: 1, category: 'expense-child'),
      ], categories: metadata);
      expect(result.expense, BigInt.from(123));
      expect(result.income, BigInt.from(456));
      expect(result.expenseStats.groups.single.category!.id, 'income');
      expect(result.incomeStats.groups.single.category!.id, 'expense');
      expect(
        _ids(
          result.categoryBills(
            const ReportCategoryFilter.root('income'),
            type: 0,
          ),
        ),
        ['old-expense'],
      );
      expect(
        _ids(
          result.categoryBills(
            const ReportCategoryFilter.root('expense'),
            type: 1,
          ),
        ),
        ['old-income'],
      );
      _expectConserved(result);
    });

    test('同名不同ID分类保持独立，精确ID筛选不会按名称合并', () {
      final metadata = [
        _category('a', name: '餐饮'),
        _category('b', name: '餐饮'),
        _category('a-child', parent: 'a', name: '午餐'),
        _category('b-child', parent: 'b', name: '午餐'),
      ];
      final result = _report([
        _bill('a-direct', 100, category: 'a'),
        _bill('a-child', 200, category: 'a-child'),
        _bill('b-child', 300, category: 'b-child'),
      ], categories: metadata);
      expect(result.expenseStats.groups, hasLength(2));
      expect(_ids(result.categoryBills(const ReportCategoryFilter.root('a'))), [
        'a-child',
        'a-direct',
      ]);
      expect(
        _ids(result.categoryBills(const ReportCategoryFilter.exact('b-child'))),
        ['b-child'],
      );
    });
  });

  group('完整性精度稳定排序与快照', () {
    test('超过十类完整保留，全部图项明细的并集与金额等于报告集合', () {
      final categories = [
        for (var i = 0; i < 15; i++) _category('category-$i', sort: i),
      ];
      final result = _report([
        for (var i = 0; i < 15; i++)
          _bill('bill-$i', (i + 1) * 29, category: 'category-$i'),
        _bill('unknown', 31, category: 'missing'),
      ], categories: categories);
      expect(result.expenseStats.groups, hasLength(16));
      expect(result.bills, hasLength(16));
      expect(result.expense, BigInt.from(3511));
      final detailIds = <String>[];
      for (final group in result.expenseStats.groups) {
        final details = result.categoryBills(
          group.category == null
              ? const ReportCategoryFilter.uncategorized()
              : ReportCategoryFilter.root(group.category!.id),
          type: 0,
        );
        detailIds.addAll(_ids(details));
        expect(
          details.fold(BigInt.zero, (sum, b) => sum + BigInt.from(b.amount)),
          group.amount,
        );
      }
      expect(detailIds, hasLength(16));
      expect(detailIds.toSet(), _ids(result.bills).toSet());
      _expectConserved(result);
    });

    test('超过int64的原币聚合保持末位精度和分类排序，结余不溢出', () {
      const max = 9223372036854775807;
      final result = _report(
        [
          _bill('max-a', max, category: 'food', currency: 'JPY'),
          _bill('one', 1, category: 'lunch', currency: 'JPY'),
          _bill('max-b', max, category: 'other', currency: 'JPY'),
          _bill('income-max', max, type: 1, currency: 'JPY'),
          _bill('income-two', 2, type: 1, currency: 'JPY'),
        ],
        categories: [
          _category('food'),
          _category('lunch', parent: 'food'),
          _category('other'),
        ],
        currency: 'JPY',
      );
      expect(result.expense, BigInt.parse('18446744073709551615'));
      expect(result.income, BigInt.parse('9223372036854775809'));
      expect(result.balance, BigInt.parse('-9223372036854775806'));
      expect(result.expenseStats.groups.map((g) => g.category!.id), [
        'food',
        'other',
      ]);
      expect(
        result.expenseStats.groups.first.amount,
        BigInt.parse('9223372036854775808'),
      );
      expect(result.expenseStats.groups.first.directAmount, BigInt.from(max));
      expect(
        result.expenseStats.groups.first.children.single.amount,
        BigInt.one,
      );
      _expectConserved(result);
    });

    test('账单按时间降序再ID升序，输入倒序不改变排序或图项平局顺序', () {
      final categories = [
        _category('root-b', sort: 5),
        _category('root-a', sort: 5),
        _category('early', sort: 0),
      ];
      final bills = [
        _bill('same-b', 100, category: 'root-b', dateMs: 100),
        _bill('old', 100, category: 'early', dateMs: 1),
        _bill('same-a', 100, category: 'root-a', dateMs: 100),
        _bill('new', 100, dateMs: 1000),
      ];
      final result = _report(bills, categories: categories);
      final reversed = _report(bills.reversed, categories: categories.reversed);
      expect(_ids(result.bills), ['new', 'same-a', 'same-b', 'old']);
      expect(_ids(reversed.bills), _ids(result.bills));
      expect(result.expenseStats.groups.map((g) => g.category?.id), [
        'early',
        'root-a',
        'root-b',
        null,
      ]);
      expect(reversed.expenseStats.groups.map((g) => g.category?.id), [
        'early',
        'root-a',
        'root-b',
        null,
      ]);
    });

    test('报告筛选不会排序或更改输入，输出各层列表均不可修改', () {
      final categories = [
        _category('food'),
        _category('lunch', parent: 'food'),
      ];
      final bills = [
        _bill('old', 29, category: 'food', dateMs: 1),
        _bill('new', 31, category: 'lunch', dateMs: 2),
        _bill('income', 37, type: 1, dateMs: 3),
      ];
      final categorySnapshot = categories.map((c) => c.toJson()).toList();
      final billSnapshot = bills.map((b) => b.toJson()).toList();
      final result = _report(bills, categories: categories);
      expect(categories.map((c) => c.toJson()).toList(), categorySnapshot);
      expect(bills.map((b) => b.toJson()).toList(), billSnapshot);
      expect(() => result.bills.clear(), throwsUnsupportedError);
      expect(() => result.expenseBills.clear(), throwsUnsupportedError);
      expect(() => result.incomeBills.clear(), throwsUnsupportedError);
      expect(() => result.expenseStats.groups.clear(), throwsUnsupportedError);
      expect(
        () => result.expenseStats.groups.single.children.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => result.categoryBills(const ReportCategoryFilter.all()).clear(),
        throwsUnsupportedError,
      );
      _expectConserved(result);
    });

    test('报告复制分类元数据与选择ID，外部清空输入后明细快照仍准确', () {
      final ids = ['food', 'lunch'];
      final selection = ReportCategoryFilter.exactIds(ids);
      expect(() => selection.ids.add('other'), throwsUnsupportedError);
      final categories = [
        _category('food'),
        _category('lunch', parent: 'food'),
      ];
      final bills = [
        _bill('root', 29, category: 'food'),
        _bill('child', 31, category: 'lunch'),
      ];
      ids.clear();
      final result = _report(
        bills,
        categories: categories,
        category: selection,
      );
      categories.clear();
      bills.clear();
      expect(result.expense, BigInt.from(60));
      expect(_ids(result.bills), ['child', 'root']);
      expect(
        _ids(result.categoryBills(const ReportCategoryFilter.root('food'))),
        ['child', 'root'],
      );
      expect(
        _ids(result.categoryBills(const ReportCategoryFilter.exact('lunch'))),
        ['child'],
      );
      expect(
        _ids(result.categoryBills(const ReportCategoryFilter.uncategorized())),
        isEmpty,
      );
      _expectConserved(result);
    });
  });
}
