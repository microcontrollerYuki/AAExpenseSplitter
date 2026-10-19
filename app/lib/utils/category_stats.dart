import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import 'report_filter.dart';

class CategoryStatAmount {
  const CategoryStatAmount({required this.category, required this.amount});

  final Category category;
  final BigInt amount;
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
  final BigInt amount;
  final BigInt directAmount;
  final bool hasChildren;
  final List<CategoryStatAmount> children;
}

class CategoryStats {
  CategoryStats({
    required this.total,
    required Iterable<CategoryStatGroup> groups,
  }) : groups = List.unmodifiable(groups);

  final BigInt total;
  final List<CategoryStatGroup> groups;
}

/// Aggregates one transaction currency in exact integer minor units, or —
/// with [currency] null — every currency at once (CNY conversion views).
/// Each bill belongs to one root and either its direct amount or one child,
/// never both. The shared hierarchy keeps malformed old nodes bounded and
/// read-only. [amountOf] replaces the stored amount (CNY conversion passes
/// the R-09 per-bill value); bills without a lookup value must be filtered
/// out by the caller.
CategoryStats aggregateCategoryStats({
  required Iterable<Bill> bills,
  required Iterable<Category> categories,
  required int type,
  String? currency = 'CNY',
  BigInt Function(Bill bill)? amountOf,
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
  final totals = <String?, BigInt>{};
  final direct = <String?, BigInt>{};
  final children = <String, Map<String, BigInt>>{};
  var total = BigInt.zero;
  for (final bill in filterReportBills(
    bills: bills,
    categories: byId.values,
    filter: ReportFilter(currency: currency, type: type),
  )) {
    final category = byId[bill.categoryId];
    final root = hierarchy.rootOf(category?.id);
    final amount =
        amountOf?.call(bill) ?? BigInt.from(bill.amount);
    totals[root?.id] = (totals[root?.id] ?? BigInt.zero) + amount;
    total += amount;
    if (root == null || root.id == category!.id) {
      direct[root?.id] = (direct[root?.id] ?? BigInt.zero) + amount;
    } else {
      final amounts = children.putIfAbsent(root.id, () => {});
      amounts[category.id] = (amounts[category.id] ?? BigInt.zero) + amount;
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
            directAmount: direct[entry.key] ?? BigInt.zero,
            hasChildren:
                entry.key != null &&
                hierarchy.childrenOf(entry.key!).isNotEmpty,
            children:
                [
                  for (final child
                      in (children[entry.key] ?? <String, BigInt>{}).entries)
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
