import '../data/app_database.dart';
import '../data/category_hierarchy.dart';

class CategoryStatAmount {
  const CategoryStatAmount({required this.category, required this.amount});

  final Category category;
  final int amount;
}

class CategoryStatGroup {
  CategoryStatGroup({
    required this.category,
    required this.amount,
    required this.directAmount,
    required this.hasChildren,
    required Iterable<CategoryStatAmount> children,
  }) : children = List.unmodifiable(children);

  /// null represents both unassigned bills and missing historical categories.
  final Category? category;
  final int amount;
  final int directAmount;
  final bool hasChildren;
  final List<CategoryStatAmount> children;
}

class CategoryStats {
  CategoryStats({
    required this.total,
    required Iterable<CategoryStatGroup> groups,
  }) : groups = List.unmodifiable(groups);

  final int total;
  final List<CategoryStatGroup> groups;
}

/// Aggregates an already date-filtered collection in integer cents. Each bill
/// belongs to one root and either its direct amount or one child, never both.
/// The shared hierarchy keeps malformed old nodes bounded and read-only.
CategoryStats aggregateCategoryStats({
  required Iterable<Bill> bills,
  required Iterable<Category> categories,
  required int type,
}) {
  if (type != 0 && type != 1) {
    throw ArgumentError.value(
      type,
      'type',
      'Only expense or income is supported',
    );
  }
  final byId = {for (final category in categories) category.id: category};
  final hierarchy = CategoryHierarchy(byId.values);
  final totals = <String?, int>{};
  final direct = <String?, int>{};
  final children = <String, Map<String, int>>{};
  var total = 0;
  for (final bill in bills) {
    if (bill.type != type || bill.deletedAt != null) continue;
    final category = byId[bill.categoryId];
    // Match the existing monthly summary: AA receivables are internal income;
    // actual expenses (including historical kind=2 references) still count.
    if (type == 1 && category?.kind == 2) continue;
    final root = hierarchy.rootOf(category?.id);
    totals[root?.id] = (totals[root?.id] ?? 0) + bill.amount;
    total += bill.amount;
    if (root == null || root.id == category!.id) {
      direct[root?.id] = (direct[root?.id] ?? 0) + bill.amount;
    } else {
      final amounts = children.putIfAbsent(root.id, () => {});
      amounts[category.id] = (amounts[category.id] ?? 0) + bill.amount;
    }
  }

  int categoryOrder(Category? a, Category? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    final order = a.sort.compareTo(b.sort);
    return order == 0 ? a.id.compareTo(b.id) : order;
  }

  final groups =
      [
        for (final entry in totals.entries)
          CategoryStatGroup(
            category: byId[entry.key],
            amount: entry.value,
            directAmount: direct[entry.key] ?? 0,
            hasChildren:
                entry.key != null &&
                hierarchy.childrenOf(entry.key!).isNotEmpty,
            children:
                [
                  for (final child
                      in (children[entry.key] ?? <String, int>{}).entries)
                    CategoryStatAmount(
                      category: byId[child.key]!,
                      amount: child.value,
                    ),
                ]..sort((a, b) {
                  final order = b.amount.compareTo(a.amount);
                  return order == 0
                      ? categoryOrder(a.category, b.category)
                      : order;
                }),
          ),
      ]..sort((a, b) {
        final order = b.amount.compareTo(a.amount);
        return order == 0 ? categoryOrder(a.category, b.category) : order;
      });
  return CategoryStats(total: total, groups: groups);
}
