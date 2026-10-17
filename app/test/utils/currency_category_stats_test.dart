import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/utils/category_stats.dart';

import '../helpers/test_support.dart';

Category _category(String id, {String? parent, int kind = 0}) => Category(
  id: id,
  parentId: parent,
  name: id,
  emoji: '🍜',
  kind: kind,
  sort: 0,
  isPreset: false,
);

void main() {
  test('六币种同额独立聚合，USD原币10不计入CNY实际扣款72', () {
    const codes = ['CNY', 'USD', 'HKD', 'EUR', 'JPY', 'GBP'];
    final bills = [
      for (final code in codes)
        mkBill(
          code,
          amount: 1000,
          currency: code,
          accountAmount: code == 'USD' ? 7200 : 1000,
        ),
    ];
    for (final code in codes) {
      final result = aggregateCategoryStats(
        bills: bills,
        categories: const [],
        type: 0,
        currency: code,
      );
      expect(result.total, BigInt.from(1000), reason: code);
      expect(result.groups.single.amount, BigInt.from(1000), reason: code);
    }
    expect(
      aggregateCategoryStats(bills: bills, categories: const [], type: 0).total,
      BigInt.from(1000),
      reason: '旧调用默认CNY也不能合并其他币种',
    );
  });

  test('同一父子分类按选择币种分别直属与分项且不重复', () {
    final categories = [_category('food'), _category('lunch', parent: 'food')];
    final bills = [
      for (final code in ['CNY', 'USD', 'JPY']) ...[
        mkBill(
          '$code-direct',
          amount: 1000,
          currency: code,
          categoryId: 'food',
        ),
        mkBill(
          '$code-child',
          amount: 2000,
          currency: code,
          categoryId: 'lunch',
        ),
      ],
    ];
    for (final code in ['CNY', 'USD', 'JPY']) {
      final result = aggregateCategoryStats(
        bills: bills,
        categories: categories,
        type: 0,
        currency: code,
      );
      expect(result.total, BigInt.from(3000));
      expect(result.groups, hasLength(1));
      final group = result.groups.single;
      expect(group.directAmount, BigInt.from(1000));
      expect(group.children.single.amount, BigInt.from(2000));
      expect(group.children.single.category.id, 'lunch');
      expect(group.hasChildren, isTrue);
    }
  });

  test('外币保留收支排除规则：软删转账调账与内部收入不混入', () {
    final categories = [_category('internal', kind: 2), _category('ordinary')];
    final bills = [
      mkBill('expense', amount: 1000, currency: 'USD', categoryId: 'ordinary'),
      mkBill('income', type: 1, amount: 2000, currency: 'USD'),
      mkBill(
        'internal-income',
        type: 1,
        amount: 9000,
        currency: 'USD',
        categoryId: 'internal',
      ),
      mkBill(
        'old-internal-expense',
        amount: 300,
        currency: 'USD',
        categoryId: 'internal',
      ),
      mkBill('transfer', type: 2, amount: 8000, currency: 'USD'),
      mkBill('adjustment', type: 3, amount: 7000, currency: 'USD'),
      mkBill('deleted-expense', amount: 6000, currency: 'USD', deletedAt: 1),
      mkBill(
        'deleted-income',
        type: 1,
        amount: 5000,
        currency: 'USD',
        deletedAt: 1,
      ),
      mkBill('other-currency', amount: 4000, currency: 'JPY'),
    ];
    final expense = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 0,
      currency: 'USD',
    );
    final income = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 1,
      currency: 'USD',
    );
    expect(expense.total, BigInt.from(1300));
    expect(income.total, BigInt.from(2000));
  });

  test('一级直属和二级合计MAX+1保持精确且排序不溢出', () {
    const max = 9223372036854775807;
    final categories = [
      _category('food'),
      _category('lunch', parent: 'food'),
      _category('other'),
    ];
    final result = aggregateCategoryStats(
      bills: [
        mkBill('max', amount: max, currency: 'JPY', categoryId: 'food'),
        mkBill('one', amount: 1, currency: 'JPY', categoryId: 'lunch'),
        mkBill('other', amount: 2, currency: 'JPY', categoryId: 'other'),
      ],
      categories: categories,
      type: 0,
      currency: 'JPY',
    );
    expect(result.total, BigInt.parse('9223372036854775810'));
    expect(result.groups.first.category!.id, 'food');
    expect(result.groups.first.amount, BigInt.parse('9223372036854775808'));
    expect(result.groups.first.directAmount, BigInt.from(max));
    expect(result.groups.first.children.single.amount, BigInt.one);
    expect(
      result.groups.fold(BigInt.zero, (sum, group) => sum + group.amount),
      result.total,
    );
  });

  test('未知代码与空代码保持独立，未找到币种不默认人民币', () {
    final bills = [
      mkBill('cny', amount: 1000),
      mkBill('unknown', amount: 999, currency: 'XTS'),
      mkBill('blank', amount: 17, currency: ''),
    ];
    for (final entry in {'XTS': 999, '': 17, 'CNY': 1000, 'USD': 0}.entries) {
      final result = aggregateCategoryStats(
        bills: bills,
        categories: const [],
        type: 0,
        currency: entry.key,
      );
      expect(result.total, BigInt.from(entry.value));
      if (entry.value == 0) expect(result.groups, isEmpty);
    }
  });
}
