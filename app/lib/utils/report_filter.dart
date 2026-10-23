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

/// 自定义日期范围：界面选择首末两个日历日（都包含）。[period] 转为起日
/// 零点到结束日次日零点的左闭右开区间，由 [ReportPeriod.inclusiveDays]
/// 用日历字段构造，不用固定毫秒数代替日历日。
class ReportDateRange {
  ReportDateRange({required DateTime start, required DateTime end})
    : firstDay = DateTime(start.year, start.month, start.day),
      lastDay = DateTime(end.year, end.month, end.day) {
    if (lastDay.isBefore(firstDay)) {
      throw ArgumentError('Range end must not be before start');
    }
  }

  /// 起日零点。
  final DateTime firstDay;

  /// 结束日零点（结束日当天仍在区间内）。
  final DateTime lastDay;

  /// 首末日包含的左闭右开报表区间。
  ReportPeriod get period => ReportPeriod.inclusiveDays(firstDay, lastDay);

  /// 区间包含的日历天数（首末都算）；用 UTC 日历日差，不受时区偏移影响。
  int get dayCount =>
      DateTime.utc(lastDay.year, lastDay.month, lastDay.day)
          .difference(DateTime.utc(firstDay.year, firstDay.month, firstDay.day))
          .inDays +
      1;

  /// 整体平移 [days] 个日历日，跨度不变；日字段进位由 DateTime 处理。
  ReportDateRange shiftDays(int days) => ReportDateRange(
    start: DateTime(firstDay.year, firstDay.month, firstDay.day + days),
    end: DateTime(lastDay.year, lastDay.month, lastDay.day + days),
  );

  @override
  bool operator ==(Object other) =>
      other is ReportDateRange &&
      other.firstDay == firstDay &&
      other.lastDay == lastDay;

  @override
  int get hashCode => Object.hash(firstDay, lastDay);
}

/// 展示用范围标签：同年省略结束年份，跨年两侧都带年份。
String reportDateRangeLabel(ReportDateRange range) {
  final first = range.firstDay;
  final last = range.lastDay;
  if (first.year == last.year) {
    return '${first.year}年${first.month}月${first.day}日'
        ' ~ ${last.month}月${last.day}日';
  }
  return '${first.year}年${first.month}月${first.day}日'
      ' ~ ${last.year}年${last.month}月${last.day}日';
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
    this.currency,
    this.type,
    this.category = const ReportCategoryFilter.all(),
  }) {
    if (type != null && type != 0 && type != 1) {
      throw ArgumentError.value(type, 'type', 'Only income or expense');
    }
  }

  /// Null selects every stored currency for CNY conversion views; a code
  /// selects that exact stored identity, including unknown historical codes.
  final String? currency;
  final ReportPeriod? period;
  final int? type;
  final ReportCategoryFilter category;

  /// Every currency in one immutable selection; the CNY conversion model
  /// consumes this set, original-currency views keep single-currency filters.
  /// Validation delegates to the main constructor.
  ReportFilter.allCurrencies({
    ReportPeriod? period,
    int? type,
    ReportCategoryFilter category = const ReportCategoryFilter.all(),
  }) : this(period: period, currency: null, type: type, category: category);
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
                (filter.currency == null ||
                    bill.currency == filter.currency) &&
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
