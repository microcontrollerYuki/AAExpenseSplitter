import '../data/app_database.dart';
import 'category_stats.dart';
import 'report_filter.dart';

export 'report_filter.dart';

/// All values and drill-down collections are derived from this immutable
/// selection. A provider refresh builds a new result rather than mutating it.
/// All-currency selections (filter.currency == null) are conversion inputs
/// for the R-09 model only: their raw income/expense sums mix units, and the
/// original-currency category statistics require a single-currency filter.
class ReportResult {
  ReportResult._(this.filter, this.bills, this._categories)
    : incomeBills = List.unmodifiable(bills.where((b) => b.type == 1)),
      expenseBills = List.unmodifiable(bills.where((b) => b.type == 0));

  final ReportFilter filter;
  final List<Bill> bills;
  final List<Category> _categories;
  final List<Bill> incomeBills;
  final List<Bill> expenseBills;

  late final BigInt income = incomeBills.fold(
    BigInt.zero,
    (sum, b) => sum + BigInt.from(b.amount),
  );
  late final BigInt expense = expenseBills.fold(
    BigInt.zero,
    (sum, b) => sum + BigInt.from(b.amount),
  );
  BigInt get balance => income - expense;
  late final CategoryStats incomeStats = aggregateCategoryStats(
    bills: incomeBills,
    categories: _categories,
    type: 1,
    currency: _statsCurrency,
  );
  late final CategoryStats expenseStats = aggregateCategoryStats(
    bills: expenseBills,
    categories: _categories,
    type: 0,
    currency: _statsCurrency,
  );

  String get _statsCurrency {
    final currency = filter.currency;
    if (currency == null) {
      throw StateError('原币分类统计需要单币种筛选；全币种结果请使用 CNY 折算模型');
    }
    return currency;
  }

  List<Bill> categoryBills(ReportCategoryFilter category, {int? type}) =>
      filterReportBills(
        bills: bills,
        categories: _categories,
        filter: ReportFilter(
          period: filter.period,
          currency: filter.currency,
          type: type,
          category: category,
        ),
      );
}

ReportResult buildReport({
  required Iterable<Bill> bills,
  required Iterable<Category> categories,
  required ReportFilter filter,
}) {
  final metadata = List<Category>.unmodifiable(categories);
  return ReportResult._(
    filter,
    filterReportBills(bills: bills, categories: metadata, filter: filter),
    metadata,
  );
}
