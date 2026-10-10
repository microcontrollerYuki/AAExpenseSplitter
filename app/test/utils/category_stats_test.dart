import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/utils/category_stats.dart';

Category statsCategory(
  String id, {
  String? name,
  int kind = 0,
  String? parent,
  int sort = 0,
}) => Category(
  id: id,
  parentId: parent,
  name: name ?? id,
  emoji: '🍜',
  kind: kind,
  sort: sort,
  isPreset: false,
);

Bill statsBill(
  String id,
  int amount, {
  String? category,
  int type = 0,
  int? deletedAt,
  String? groupId,
  String? settlementId,
}) => Bill(
  id: id,
  type: type,
  amount: amount,
  categoryId: category,
  accountId: 'account',
  toAccountId: null,
  dateMs: 1234567890000,
  note: '统计测试 $id',
  isAa: groupId != null,
  aaGroupId: groupId,
  settlementId: settlementId,
  createdAt: 77,
  updatedAt: 88,
  deletedAt: deletedAt,
);

CategoryStatGroup statsGroup(CategoryStats stats, String? id) =>
    stats.groups.singleWhere((group) => group.category?.id == id);

List<Object?> statsRows(CategoryStats stats) => [
  stats.total,
  for (final group in stats.groups)
    [
      group.category?.id,
      group.amount,
      group.directAmount,
      group.hasChildren,
      for (final child in group.children) [child.category.id, child.amount],
    ],
];

void main() {
  test('一级直属10加二级20和30合计60，每条账单只计一次', () {
    final categories = [
      statsCategory('food', name: '餐饮'),
      statsCategory('lunch', parent: 'food', name: '午餐'),
      statsCategory('dinner', parent: 'food', name: '晚餐'),
    ];
    final result = aggregateCategoryStats(
      bills: [
        statsBill('direct', 1000, category: 'food'),
        statsBill('lunch-a', 800, category: 'lunch'),
        statsBill('lunch-b', 1200, category: 'lunch'),
        statsBill('dinner', 3000, category: 'dinner'),
      ],
      categories: categories,
      type: 0,
    );
    expect(result.total, 6000);
    expect(result.groups, hasLength(1));
    final food = result.groups.single;
    expect(food.category, categories.first);
    expect(food.amount, 6000);
    expect(food.directAmount, 1000);
    expect(food.hasChildren, isTrue);
    expect(food.children.map((child) => child.category.id), [
      'dinner',
      'lunch',
    ]);
    expect(food.children.map((child) => child.amount), [3000, 2000]);
    expect(
      food.directAmount +
          food.children.fold<int>(0, (sum, child) => sum + child.amount),
      food.amount,
    );
  });

  test('收入聚合使用收入父子，不混入支出转账调账和软删除收入', () {
    final result = aggregateCategoryStats(
      bills: [
        statsBill('salary', 500000, category: 'salary', type: 1),
        statsBill('bonus', 25000, category: 'bonus', type: 1),
        statsBill('expense', 9000, category: 'salary'),
        statsBill('transfer', 8000, category: 'salary', type: 2),
        statsBill('adjustment', 7000, category: 'salary', type: 3),
        statsBill(
          'deleted-income',
          6000,
          category: 'bonus',
          type: 1,
          deletedAt: 1,
        ),
      ],
      categories: [
        statsCategory('salary', kind: 1),
        statsCategory('bonus', kind: 1, parent: 'salary'),
      ],
      type: 1,
    );
    expect(result.total, 525000);
    final salary = result.groups.single;
    expect(salary.category!.id, 'salary');
    expect(salary.directAmount, 500000);
    expect(salary.children.single.category.id, 'bonus');
    expect(salary.children.single.amount, 25000);
  });

  test('保持明细口径：AA支出和历史kind2支出保留，仅排kind2内部收入', () {
    final categories = [
      statsCategory('expense'),
      statsCategory('income', kind: 1),
      statsCategory('internal', kind: 2),
      statsCategory('internal-invalid-child', kind: 2, parent: 'expense'),
    ];
    final bills = [
      statsBill('aa-original', 1000, category: 'expense', groupId: 'original'),
      statsBill('aa-share', 300, category: 'expense', groupId: 'share'),
      statsBill(
        'settlement-expense',
        200,
        category: 'expense',
        settlementId: 'settlement',
      ),
      statsBill('historical-internal-expense', 400, category: 'internal'),
      statsBill('normal-income', 600, category: 'income', type: 1),
      statsBill(
        'settlement-income',
        700,
        category: 'income',
        type: 1,
        settlementId: 'settlement',
      ),
      statsBill(
        'aa-normal-category-income',
        100,
        category: 'income',
        type: 1,
        groupId: 'normal-income',
      ),
      statsBill(
        'internal-income',
        2000,
        category: 'internal',
        type: 1,
        groupId: 'old-internal',
      ),
      statsBill(
        'invalid-internal-income',
        3000,
        category: 'internal-invalid-child',
        type: 1,
      ),
      statsBill(
        'deleted-aa',
        5000,
        category: 'expense',
        groupId: 'deleted',
        deletedAt: 1,
      ),
    ];
    final expense = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 0,
    );
    expect(expense.total, 1900);
    expect(statsGroup(expense, 'expense').amount, 1500);
    expect(statsGroup(expense, 'internal').amount, 400);
    final income = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 1,
    );
    expect(income.total, 1400);
    expect(income.groups.single.category!.id, 'income');
    expect(income.groups.single.amount, 1400);
  });

  test('无分类和失效ID统一未分类一组，不重复或丢失金额', () {
    final result = aggregateCategoryStats(
      bills: [
        statsBill('null', 100),
        statsBill('missing-a', 200, category: 'missing-a'),
        statsBill('missing-b', 300, category: 'missing-b'),
        statsBill('empty-id', 400, category: ''),
        statsBill('valid', 500, category: 'valid'),
      ],
      categories: [statsCategory('valid')],
      type: 0,
    );
    expect(result.total, 1500);
    expect(result.groups, hasLength(2));
    final uncategorized = statsGroup(result, null);
    expect(uncategorized.amount, 1000);
    expect(uncategorized.directAmount, 1000);
    expect(uncategorized.children, isEmpty);
    expect(uncategorized.hasChildren, isFalse);
    expect(statsGroup(result, 'valid').amount, 500);
  });

  test('同名不同ID的一级和二级各保留所属分组，不能按名称合并', () {
    final result = aggregateCategoryStats(
      bills: [
        statsBill('a-direct', 10, category: 'root-a'),
        statsBill('a-child', 20, category: 'child-a'),
        statsBill('b-child', 30, category: 'child-b'),
      ],
      categories: [
        statsCategory('root-a', name: '同名一级'),
        statsCategory('root-b', name: '同名一级'),
        statsCategory('child-a', parent: 'root-a', name: '同名二级'),
        statsCategory('child-b', parent: 'root-b', name: '同名二级'),
      ],
      type: 0,
    );
    expect(result.total, 60);
    expect(result.groups.map((group) => group.category!.id), [
      'root-a',
      'root-b',
    ]);
    expect(statsGroup(result, 'root-a').amount, 30);
    expect(statsGroup(result, 'root-b').amount, 30);
    expect(statsGroup(result, 'root-a').children.single.category.id, 'child-a');
    expect(statsGroup(result, 'root-b').children.single.category.id, 'child-b');
  });

  test('孤儿跨类型父级自环双环和三级按独立根回退，不递归不漏账', () {
    final categories = [
      statsCategory('root'),
      statsCategory('child', parent: 'root'),
      statsCategory('orphan', parent: 'missing'),
      statsCategory('cross', kind: 1, parent: 'root'),
      statsCategory('self', parent: 'self'),
      statsCategory('cycle-a', parent: 'cycle-b'),
      statsCategory('cycle-b', parent: 'cycle-a'),
      statsCategory('third', parent: 'child'),
    ];
    final bills = [
      statsBill('root', 100, category: 'root'),
      statsBill('child', 200, category: 'child'),
      statsBill('orphan', 300, category: 'orphan'),
      statsBill('cross', 400, category: 'cross'),
      statsBill('self', 500, category: 'self'),
      statsBill('cycle-a', 600, category: 'cycle-a'),
      statsBill('cycle-b', 700, category: 'cycle-b'),
      statsBill('third', 800, category: 'third'),
    ];
    final result = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 0,
    );
    expect(result.total, 3600);
    expect(result.groups.map((group) => group.category!.id).toSet(), {
      'root',
      'orphan',
      'cross',
      'self',
      'cycle-a',
      'cycle-b',
      'third',
    });
    expect(statsGroup(result, 'root').amount, 300);
    expect(statsGroup(result, 'root').directAmount, 100);
    expect(statsGroup(result, 'root').children.single.category.id, 'child');
    for (final id in [
      'orphan',
      'cross',
      'self',
      'cycle-a',
      'cycle-b',
      'third',
    ]) {
      final group = statsGroup(result, id);
      expect(group.children, isEmpty, reason: id);
      expect(group.directAmount, group.amount, reason: id);
    }
    expect(
      result.groups.fold<int>(0, (sum, group) => sum + group.amount),
      result.total,
    );
  });

  test('历史账单类型与分类kind不一致时仍按分类合法父级归属保留', () {
    final categories = [
      statsCategory('expense-parent'),
      statsCategory('expense-child', parent: 'expense-parent'),
      statsCategory('income-parent', kind: 1),
      statsCategory('income-child', kind: 1, parent: 'income-parent'),
    ];
    final bills = [
      statsBill('old-expense', 123, category: 'income-child'),
      statsBill('old-income', 456, category: 'expense-child', type: 1),
    ];
    final expense = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 0,
    );
    expect(expense.total, 123);
    expect(expense.groups.single.category!.id, 'income-parent');
    expect(expense.groups.single.children.single.category.id, 'income-child');
    final income = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 1,
    );
    expect(income.total, 456);
    expect(income.groups.single.category!.id, 'expense-parent');
    expect(income.groups.single.children.single.category.id, 'expense-child');
  });

  test('金额降序后以分类sort和ID稳定排序，输入倒序不影响结果', () {
    final categories = [
      statsCategory('top', sort: 99),
      statsCategory('root-b', sort: 5),
      statsCategory('root-a', sort: 5),
      statsCategory('early', sort: 0),
      statsCategory('parent', sort: 2),
      statsCategory('child-b', parent: 'parent', sort: 5),
      statsCategory('child-a', parent: 'parent', sort: 5),
      statsCategory('child-early', parent: 'parent', sort: 0),
    ];
    final bills = [
      statsBill('top', 500, category: 'top'),
      statsBill('b', 100, category: 'root-b'),
      statsBill('a', 100, category: 'root-a'),
      statsBill('early', 100, category: 'early'),
      statsBill('direct', 40, category: 'parent'),
      statsBill('child-b', 20, category: 'child-b'),
      statsBill('child-a', 20, category: 'child-a'),
      statsBill('child-early', 20, category: 'child-early'),
      statsBill('unknown', 100),
    ];
    final result = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 0,
    );
    expect(result.groups.map((group) => group.category?.id), [
      'top',
      'early',
      'parent',
      'root-a',
      'root-b',
      null,
    ]);
    expect(
      statsGroup(result, 'parent').children.map((child) => child.category.id),
      ['child-early', 'child-a', 'child-b'],
    );
    final reversed = aggregateCategoryStats(
      bills: bills.reversed,
      categories: categories.reversed,
      type: 0,
    );
    expect(statsRows(reversed), statsRows(result));
  });

  test('有无二级按树判断，但只显示本期有账单的二级且无直属金额为零', () {
    final result = aggregateCategoryStats(
      bills: [
        statsBill('direct', 500, category: 'direct-parent'),
        statsBill('child', 700, category: 'billed-child'),
        statsBill('leaf', 200, category: 'leaf'),
      ],
      categories: [
        statsCategory('direct-parent'),
        statsCategory('unused-child', parent: 'direct-parent'),
        statsCategory('child-parent'),
        statsCategory('billed-child', parent: 'child-parent'),
        statsCategory('other-unused-child', parent: 'child-parent'),
        statsCategory('leaf'),
      ],
      type: 0,
    );
    final direct = statsGroup(result, 'direct-parent');
    expect(direct.hasChildren, isTrue);
    expect(direct.directAmount, 500);
    expect(direct.children, isEmpty);
    final withChild = statsGroup(result, 'child-parent');
    expect(withChild.hasChildren, isTrue);
    expect(withChild.directAmount, 0);
    expect(withChild.children.single.category.id, 'billed-child');
    expect(statsGroup(result, 'leaf').hasChildren, isFalse);
    expect(statsGroup(result, 'leaf').children, isEmpty);
  });

  test('聚合不修改输入且输出列表不可变，空结果和非法type有明确行为', () {
    final categories = [
      statsCategory('root'),
      statsCategory('child', parent: 'root'),
    ];
    final bills = [
      statsBill('cent-a', 1, category: 'root'),
      statsBill('cent-b', 2, category: 'child'),
    ];
    final categorySnapshot = categories
        .map((category) => category.toJson())
        .toList();
    final billSnapshot = bills.map((bill) => bill.toJson()).toList();
    final result = aggregateCategoryStats(
      bills: bills,
      categories: categories,
      type: 0,
    );
    expect(result.total, 3);
    expect(() => result.groups.clear(), throwsUnsupportedError);
    expect(() => result.groups.single.children.clear(), throwsUnsupportedError);
    expect(
      categories.map((category) => category.toJson()).toList(),
      categorySnapshot,
    );
    expect(bills.map((bill) => bill.toJson()).toList(), billSnapshot);
    for (final type in [0, 1]) {
      final empty = aggregateCategoryStats(
        bills: const [],
        categories: const [],
        type: type,
      );
      expect(empty.total, 0);
      expect(empty.groups, isEmpty);
    }
    for (final type in [-1, 2, 3]) {
      expect(
        () => aggregateCategoryStats(
          bills: bills,
          categories: categories,
          type: type,
        ),
        throwsArgumentError,
      );
    }
  });
}
