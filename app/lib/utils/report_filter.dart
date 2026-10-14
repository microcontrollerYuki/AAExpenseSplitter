import '../data/app_database.dart';
import '../data/category_hierarchy.dart';

/// Local calendar ranges are always [startMs, endMs). Calendar factories use
/// the supplied year/month/day fields, not a fixed number of 24-hour days.
class ReportPeriod {
  ReportPeriod({required this.startMs, required this.endMs}) {
    if (endMs <= startMs) {
      throw ArgumentError('Report end must be after start');
    }
  }

  factory ReportPeriod.month(DateTime month) => ReportPeriod(
    startMs: DateTime(month.year, month.month).millisecondsSinceEpoch,
    endMs: DateTime(month.year, month.month + 1).millisecondsSinceEpoch,
  );

  factory ReportPeriod.year(int year) => ReportPeriod(
    startMs: DateTime(year).millisecondsSinceEpoch,
    endMs: DateTime(year + 1).millisecondsSinceEpoch,
  );

  factory ReportPeriod.inclusiveDays(DateTime start, DateTime end) {
    final first = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    if (last.isBefore(first)) throw ArgumentError('Invalid report date range');
    return ReportPeriod(
      startMs: first.millisecondsSinceEpoch,
      endMs: DateTime(end.year, end.month, end.day + 1).millisecondsSinceEpoch,
    );
  }

  final int startMs;
  final int endMs;
  DateTime get start => DateTime.fromMillisecondsSinceEpoch(startMs);
  DateTime get end => DateTime.fromMillisecondsSinceEpoch(endMs);
  bool contains(int dateMs) => dateMs >= startMs && dateMs < endMs;
}

enum ReportCategoryMode { all, root, direct, exact, uncategorized, exactIds }

/// A missing requested category matches nothing. Unassigned/missing historical
/// references are selected only by the explicit uncategorized scope.
class ReportCategoryFilter {
  const ReportCategoryFilter.all()
    : mode = ReportCategoryMode.all,
      id = null,
      ids = const {};
  const ReportCategoryFilter.root(this.id)
    : mode = ReportCategoryMode.root,
      ids = const {};
  const ReportCategoryFilter.direct(this.id)
    : mode = ReportCategoryMode.direct,
      ids = const {};
  const ReportCategoryFilter.exact(this.id)
    : mode = ReportCategoryMode.exact,
      ids = const {};
  const ReportCategoryFilter.uncategorized()
    : mode = ReportCategoryMode.uncategorized,
      id = null,
      ids = const {};
  ReportCategoryFilter.exactIds(Iterable<String> categories)
    : mode = ReportCategoryMode.exactIds,
      id = null,
      ids = Set.unmodifiable(categories);

  final ReportCategoryMode mode;
  final String? id;
  final Set<String> ids;
}

class ReportFilter {
  ReportFilter({
    this.period,
    required this.currency,
    this.type,
    this.category = const ReportCategoryFilter.all(),
  }) {
    if (type != null && type != 0 && type != 1) {
      throw ArgumentError.value(type, 'type', 'Only income or expense');
    }
  }

  final ReportPeriod? period;
  // Exact stored currency identity, including unknown historical codes.
  final String currency;
  final int? type;
  final ReportCategoryFilter category;
}

/// Shared membership rules for summaries, charts and future report details.
/// AA expenses and old kind=2 expenses count; kind=2 income is internal only.
List<Bill> filterReportBills({
  required Iterable<Bill> bills,
  required Iterable<Category> categories,
  required ReportFilter filter,
}) {
  final byId = {for (final category in categories) category.id: category};
  final hierarchy = CategoryHierarchy(byId.values);
  final scope = filter.category;
  bool categoryMatches(Bill bill) {
    final category = byId[bill.categoryId];
    return switch (scope.mode) {
      ReportCategoryMode.all => true,
      ReportCategoryMode.uncategorized => category == null,
      ReportCategoryMode.root =>
        category != null && hierarchy.rootOf(category.id)?.id == scope.id,
      ReportCategoryMode.direct =>
        category != null &&
            category.id == scope.id &&
            hierarchy.rootOf(category.id)?.id == category.id,
      ReportCategoryMode.exact => category != null && category.id == scope.id,
      ReportCategoryMode.exactIds =>
        category != null && scope.ids.contains(category.id),
    };
  }

  final selected =
      bills
          .where(
            (bill) =>
                (bill.type == 0 || bill.type == 1) &&
                bill.deletedAt == null &&
                bill.currency == filter.currency &&
                (filter.type == null || bill.type == filter.type) &&
                (filter.period == null ||
                    filter.period!.contains(bill.dateMs)) &&
                !(bill.type == 1 && byId[bill.categoryId]?.kind == 2) &&
                categoryMatches(bill),
          )
          .toList()
        ..sort((a, b) {
          final date = b.dateMs.compareTo(a.dateMs);
          return date == 0 ? a.id.compareTo(b.id) : date;
        });
  return List.unmodifiable(selected);
}
