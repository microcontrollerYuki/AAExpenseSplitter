import '../data/app_database.dart';
import 'report.dart';
import 'report_conversion.dart';

/// Immutable membership and amounts for a month or one of its local days.
///
/// [bills], [incomeBills] and [expenseBills] retain the entire R-01 selection,
/// including rows missing a CNY value. [excludedBills] must remain visible as
/// not included; when [complete] is false the amounts are partial totals.
/// Every slice reads the same per-bill values, never another exchange quote.
class CalendarReportSelection {
  CalendarReportSelection._(Iterable<Bill> bills, this._values)
    : bills = List<Bill>.unmodifiable(bills);

  final List<Bill> bills;
  final Map<String, BigInt> _values;

  late final Set<String> billIds = Set<String>.unmodifiable(
    bills.map((bill) => bill.id),
  );

  late final List<Bill> incomeBills = List<Bill>.unmodifiable(
    bills.where((bill) => bill.type == 1),
  );
  late final List<Bill> expenseBills = List<Bill>.unmodifiable(
    bills.where((bill) => bill.type == 0),
  );
  late final List<Bill> includedBills = List<Bill>.unmodifiable(
    bills.where((bill) => _values.containsKey(bill.id)),
  );
  late final List<Bill> excludedBills = List<Bill>.unmodifiable(
    bills.where((bill) => !_values.containsKey(bill.id)),
  );

  bool get complete => excludedBills.isEmpty;

  /// Original minor units in a single-currency view, CNY minor units in an
  /// overview. Null marks a missing rate, unknown currency or unselected id.
  /// As with CnyConvertedBills, pass rows from this immutable selection.
  BigInt? valueFor(Bill bill) =>
      billIds.contains(bill.id) ? _values[bill.id] : null;

  BigInt _sum(Iterable<Bill> rows) => rows.fold(
    BigInt.zero,
    (sum, bill) => sum + (_values[bill.id] ?? BigInt.zero),
  );

  late final BigInt income = _sum(incomeBills);
  late final BigInt expense = _sum(expenseBills);
  BigInt get balance => income - expense;
}

/// One complete local calendar date, including empty days.
class CalendarReportDay extends CalendarReportSelection {
  CalendarReportDay._(
    this.date,
    Iterable<Bill> bills,
    Map<String, BigInt> values,
  ) : super._(bills, values);

  final DateTime date;
}

/// A whole month built from one R-01 selection and, for an overview, exactly
/// one CNY conversion pass. Rebuild after a bill/category/rate refresh; old
/// instances remain valid snapshots for their original rows and quotes.
class CalendarReport extends CalendarReportSelection {
  CalendarReport._({
    required this.month,
    required this.sourceReport,
    required this.converted,
    required List<CalendarReportDay> days,
    required Map<String, BigInt> values,
  }) : days = List<CalendarReportDay>.unmodifiable(days),
       super._(sourceReport.bills, values);

  /// Local month start, constructed from the requested calendar fields.
  final DateTime month;
  final ReportResult sourceReport;
  final CnyConvertedBills? converted;

  /// Ascending local dates from the first through the last day of the month.
  /// No leading/trailing dates from neighbouring months are inserted.
  final List<CalendarReportDay> days;

  ReportPeriod get period => sourceReport.filter.period!;
  bool get isConverted => converted != null;
  String get currency => sourceReport.filter.currency ?? 'CNY';
  FrozenCnyQuotes? get quotes => converted?.quotes;
  List<CnyExcludedCurrency> get excluded =>
      converted?.excludedView ?? const <CnyExcludedCurrency>[];

  /// Match full calendar fields; another month with the same day number is
  /// never a match. The time of day is intentionally ignored.
  CalendarReportDay? dayFor(DateTime date) {
    if (date.year != month.year || date.month != month.month) return null;
    return days[date.day - 1];
  }
}

/// R-07 calendar aggregation without database or network work.
///
/// [currency] null means a CNY overview and requires an already frozen
/// [quotes] snapshot. A non-null code selects the exact original-currency
/// identity, matching R-01. Mixed raw currencies are never added together.
/// Callers supply unique persisted bill identities, as for buildReport.
CalendarReport buildCalendarReport({
  required DateTime month,
  required Iterable<Bill> bills,
  required Iterable<Category> categories,
  required String? currency,
  FrozenCnyQuotes? quotes,
}) {
  if (currency == null && quotes == null) {
    throw ArgumentError('A CNY calendar overview requires frozen quotes');
  }
  final first = DateTime(month.year, month.month);
  final report = buildReport(
    bills: bills,
    categories: categories,
    filter: ReportFilter(period: ReportPeriod.month(first), currency: currency),
  );
  final converted = currency == null
      ? CnyConvertedBills.convert(bills: report.bills, quotes: quotes!)
      : null;
  final values =
      converted?.valuesView ??
      Map<String, BigInt>.unmodifiable({
        for (final bill in report.bills) bill.id: BigInt.from(bill.amount),
      });

  final byDate = <DateTime, List<Bill>>{};
  for (final bill in report.bills) {
    final local = DateTime.fromMillisecondsSinceEpoch(bill.dateMs);
    final date = DateTime(local.year, local.month, local.day);
    (byDate[date] ??= <Bill>[]).add(bill);
  }
  final dayCount = DateTime(first.year, first.month + 1, 0).day;
  final days = <CalendarReportDay>[
    for (var day = 1; day <= dayCount; day++)
      CalendarReportDay._(
        DateTime(first.year, first.month, day),
        byDate[DateTime(first.year, first.month, day)] ?? const <Bill>[],
        values,
      ),
  ];
  return CalendarReport._(
    month: first,
    sourceReport: report,
    converted: converted,
    days: days,
    values: values,
  );
}
