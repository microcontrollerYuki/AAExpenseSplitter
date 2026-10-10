import 'package:flutter_test/flutter_test.dart';
import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/category_hierarchy.dart';

Category cat(String id, {int kind = 0, String? parent, int sort = 0}) =>
    Category(
      id: id,
      parentId: parent,
      name: id,
      emoji: '🍜',
      kind: kind,
      sort: sort,
      isPreset: false,
    );

void main() {
  test('支出收入根级、子级、路径与直属归属使用同一层级规则', () {
    final tree = CategoryHierarchy([
      cat('餐饮'),
      cat('早餐', parent: '餐饮'),
      cat('工资', kind: 1),
      cat('兼职', kind: 1, parent: '工资'),
    ]);
    expect(tree.rootsOfKind(0).map((c) => c.id), ['餐饮']);
    expect(tree.rootsOfKind(1).map((c) => c.id), ['工资']);
    expect(tree.childrenOf('餐饮').map((c) => c.id), ['早餐']);
    expect(tree.pathOf('早餐'), '餐饮 / 早餐');
    expect(tree.pathOf('兼职'), '工资 / 兼职');
    expect(tree.rootOf('餐饮')?.id, '餐饮');
    expect(tree.rootOf('早餐')?.id, '餐饮');
    expect(tree.pathOf('餐饮'), '餐饮');
    expect(tree.rootOf('missing'), isNull);
    expect(tree.pathOf(null), '未分类');
  });

  test('异常旧孤儿、跨类型、循环、三级与内部子级有界回退且各展示一次', () {
    final rows = [
      cat('root'),
      cat('child', parent: 'root'),
      cat('orphan', parent: 'missing'),
      cat('cross', kind: 1, parent: 'root'),
      cat('self', parent: 'self'),
      cat('a', parent: 'b'),
      cat('b', parent: 'a'),
      cat('third', parent: 'child'),
      cat('internal', kind: 2),
      cat('internal-child', kind: 2, parent: 'internal'),
    ];
    final before = rows.map((c) => c.toJson()).toList();
    final tree = CategoryHierarchy(rows);
    for (final id in [
      'orphan',
      'cross',
      'self',
      'a',
      'b',
      'third',
      'internal-child',
    ]) {
      expect(tree.pathOf(id), id);
      expect(tree.rootOf(id)?.id, id);
      expect(tree.childrenOf(id), isEmpty);
    }
    final visible = [
      for (final kind in [0, 1, 2])
        for (final root in tree.rootsOfKind(kind)) ...[
          root,
          ...tree.childrenOf(root.id),
        ],
    ];
    expect(visible.map((c) => c.id).toSet(), rows.map((c) => c.id).toSet());
    expect(visible.length, rows.length);
    expect(rows.map((c) => c.toJson()).toList(), before);
  });

  test('同级排序使用 sort 并以 ID 确定同序结果，空树安全', () {
    final tree = CategoryHierarchy([
      cat('r2', sort: 8),
      cat('r1', sort: 1),
      cat('b', parent: 'r1', sort: 2),
      cat('a', parent: 'r1', sort: 2),
      cat('c', parent: 'r1', sort: 1),
    ]);
    expect(tree.rootsOfKind(0).map((c) => c.id), ['r1', 'r2']);
    expect(tree.childrenOf('r1').map((c) => c.id), ['c', 'a', 'b']);
    expect(CategoryHierarchy([]).rootsOfKind(0), isEmpty);
    expect(tree.childrenOf('missing'), isEmpty);
  });
}
