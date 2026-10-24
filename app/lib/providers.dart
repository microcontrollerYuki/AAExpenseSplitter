import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_database.dart';
import 'exchange/exchange_rate_service.dart';
import 'exchange/transfer_rate_prefill.dart';
import 'sync/aa_sync_service.dart';
import 'utils/calendar_report.dart';
import 'utils/report_conversion.dart';
import 'utils/report_filter.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final exchangeRateServiceProvider = Provider<ExchangeRateService>((ref) {
  final service = ExchangeRateService(
    store: DatabaseRateStore(ref.watch(databaseProvider)),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// C-13 转账汇率预填入口：冻结共享服务的不可变快照。
/// 测试经 pumpPage 注入可控实现，避免页面测试触网。
final transferRatePrefillProvider = Provider<TransferRatePrefill>((ref) {
  return ExchangeRatePrefill(ref.watch(exchangeRateServiceProvider));
});

final aaSyncServiceProvider = Provider<AaSyncService>(
  (ref) => AaSyncService(ref.watch(databaseProvider)),
);

/// 配对信息与本机键值（myUid / myName / partnerName / pairSecret / 同步时间）
final metaProvider = StreamProvider<Map<String, String>>(
  (ref) => ref
      .watch(databaseProvider)
      .watchMeta()
      .map((rows) => {for (final r in rows) r.key: r.value}),
);

/// 全局选中的月份（明细页 / 图表页共享），1 号作为锚点
class SelectedMonthNotifier extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1);
  }

  void selectMonth(DateTime month) {
    final selected = DateTime(month.year, month.month, 1);
    if (state != selected) state = selected;
  }

  void shift(int delta) => state = DateTime(state.year, state.month + delta, 1);
}

final selectedMonthProvider = NotifierProvider<SelectedMonthNotifier, DateTime>(
  SelectedMonthNotifier.new,
);

/// 日历独立保留月份；切换图表不会改动首页明细的月份。
final calendarMonthProvider = NotifierProvider<SelectedMonthNotifier, DateTime>(
  SelectedMonthNotifier.new,
);

class StatsCalendarModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void select(bool value) {
    if (state != value) state = value;
  }
}

final statsCalendarModeProvider =
    NotifierProvider<StatsCalendarModeNotifier, bool>(
      StatsCalendarModeNotifier.new,
    );

/// 每日明细筛选单独保留；关闭窗口或切回图表不覆盖其收支维度。
class CalendarDayTypeNotifier extends Notifier<int> {
  @override
  int build() => -1;

  void select(int type) {
    if (type != -1 && type != 0 && type != 1) {
      throw ArgumentError.value(type, 'type', 'Only all, expense or income');
    }
    if (state != type) state = type;
  }
}

final calendarDayTypeProvider = NotifierProvider<CalendarDayTypeNotifier, int>(
  CalendarDayTypeNotifier.new,
);

/// 统计视图：折合 CNY 总览（code 为 null，经 R-09 折算模型取值）或某一原币。
/// 明细 / 图表两页各自持有独立状态，互不影响；切换不改动月份与分类筛选。
class ReportViewCurrency {
  const ReportViewCurrency.converted() : code = null;
  const ReportViewCurrency.original(this.code);

  final String? code;

  bool get isConverted => code == null;

  @override
  bool operator ==(Object other) =>
      other is ReportViewCurrency && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

class BillsViewNotifier extends Notifier<ReportViewCurrency> {
  @override
  ReportViewCurrency build() => const ReportViewCurrency.converted();

  void select(ReportViewCurrency view) {
    if (state != view) state = view;
  }
}

class StatsViewNotifier extends Notifier<ReportViewCurrency> {
  @override
  ReportViewCurrency build() => const ReportViewCurrency.converted();

  void select(ReportViewCurrency view) {
    if (state != view) state = view;
  }
}

final billsViewProvider =
    NotifierProvider<BillsViewNotifier, ReportViewCurrency>(
      BillsViewNotifier.new,
    );

final statsViewProvider =
    NotifierProvider<StatsViewNotifier, ReportViewCurrency>(
      StatsViewNotifier.new,
    );

/// 统计页粒度：月（默认，沿用 selectedMonthProvider）、年
/// （selectedYearProvider）或自定义范围（selectedRangeProvider，R-06）。
enum StatsGranularity { month, year, range }

class StatsGranularityNotifier extends Notifier<StatsGranularity> {
  @override
  StatsGranularity build() => StatsGranularity.month;

  void select(StatsGranularity granularity) {
    if (state != granularity) state = granularity;
  }
}

final statsGranularityProvider =
    NotifierProvider<StatsGranularityNotifier, StatsGranularity>(
      StatsGranularityNotifier.new,
    );

/// 图表页收支维度：0 支出（默认，延续既有饼图）或 1 收入。
/// 切换只影响饼图与分类排行；粒度、月份 / 年份与币种视图互不影响。
class StatsTypeNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void select(int type) {
    if (type != 0 && type != 1) {
      throw ArgumentError.value(type, 'type', 'Only expense or income');
    }
    if (state != type) state = type;
  }
}

final statsTypeProvider = NotifierProvider<StatsTypeNotifier, int>(
  StatsTypeNotifier.new,
);

/// 年报模式所选年份（默认当前年）；与 selectedMonthProvider 互不影响。
class SelectedYearNotifier extends Notifier<int> {
  @override
  int build() => DateTime.now().year;

  void selectYear(int year) {
    if (state != year) state = year;
  }

  void shift(int delta) => selectYear(state + delta);
}

final selectedYearProvider = NotifierProvider<SelectedYearNotifier, int>(
  SelectedYearNotifier.new,
);

/// 明细页周期模式：按月（沿用 selectedMonthProvider）或自定义日期范围
/// （selectedRangeProvider）。图表页不受影响，报表组合筛选属 R-06。
enum BillsPeriodMode { month, range }

class BillsPeriodModeNotifier extends Notifier<BillsPeriodMode> {
  @override
  BillsPeriodMode build() => BillsPeriodMode.month;

  void select(BillsPeriodMode mode) {
    if (state != mode) state = mode;
  }
}

final billsPeriodModeProvider =
    NotifierProvider<BillsPeriodModeNotifier, BillsPeriodMode>(
      BillsPeriodModeNotifier.new,
    );

/// 明细页自定义日期范围（首末日包含；null 表示尚未选择过）。
/// 退出范围模式后保留，再次打开选择器时作为初始选择。
class SelectedRangeNotifier extends Notifier<ReportDateRange?> {
  @override
  ReportDateRange? build() => null;

  void select(ReportDateRange range) {
    if (state != range) state = range;
  }
}

final selectedRangeProvider =
    NotifierProvider<SelectedRangeNotifier, ReportDateRange?>(
      SelectedRangeNotifier.new,
    );

/// 图表页当前周期与展示标签（R-06）：月 / 年 / 自定义范围三种粒度共用。
/// 范围模式未选范围时按防御口径回退当月。
({ReportPeriod period, String label}) statsPeriodOf({
  required StatsGranularity granularity,
  required DateTime month,
  required int year,
  required ReportDateRange? range,
}) {
  return switch (granularity) {
    StatsGranularity.year => (period: ReportPeriod.year(year), label: '$year年'),
    StatsGranularity.range when range != null => (
      period: range.period,
      label: reportDateRangeLabel(range),
    ),
    _ => (
      period: ReportPeriod.month(month),
      label: '${month.year}年${month.month}月',
    ),
  };
}

/// 明细页当前报表周期：范围模式且已选范围用自定义区间，否则沿用所选月份。
final billsPeriodProvider = Provider<ReportPeriod>((ref) {
  if (ref.watch(billsPeriodModeProvider) == BillsPeriodMode.range) {
    final range = ref.watch(selectedRangeProvider);
    if (range != null) return range.period;
  }
  return ReportPeriod.month(ref.watch(selectedMonthProvider));
});

/// 明细页账单流：跟随 billsPeriodProvider；月模式与既有月流同口径。
final billsPageBillsProvider = StreamProvider<List<Bill>>((ref) {
  final period = ref.watch(billsPeriodProvider);
  return ref
      .watch(databaseProvider)
      .watchBillsOfRange(period.startMs, period.endMs);
});

/// 首次访问即触发缓存读取（过期或缺失时自动联网一次；幂等）。
final exchangeRateReadyProvider = Provider<ExchangeRateService>((ref) {
  final service = ref.watch(exchangeRateServiceProvider);
  unawaited(service.initialize());
  return service;
});

/// 服务每发布一次新状态自增的版本号：报表页 watch 它以在联网刷新完成后重建。
class ExchangeRateVersionNotifier extends Notifier<int> {
  @override
  int build() {
    final service = ref.watch(exchangeRateReadyProvider);
    void onChanged() => state++;
    service.addListener(onChanged);
    ref.onDispose(() => service.removeListener(onChanged));
    return 0;
  }
}

final exchangeRateVersionProvider =
    NotifierProvider<ExchangeRateVersionNotifier, int>(
      ExchangeRateVersionNotifier.new,
    );

final accountsProvider = StreamProvider<List<Account>>(
  (ref) => ref.watch(databaseProvider).watchAccounts(),
);

final categoriesProvider = StreamProvider<List<Category>>(
  (ref) => ref.watch(databaseProvider).watchCategories(),
);

final allBillsProvider = StreamProvider<List<Bill>>(
  (ref) => ref.watch(databaseProvider).watchAllBills(),
);

/// 月历与每日明细共享一个不可变快照。账单、分类或报价变化时整体
/// 重建；每日明细复用逐笔金额，不重新报价或折算。
final calendarReportProvider = Provider<AsyncValue<CalendarReport>>((ref) {
  final month = ref.watch(calendarMonthProvider);
  final view = ref.watch(statsViewProvider);
  final bills = ref.watch(allBillsProvider);
  final categories = ref.watch(categoriesProvider);
  final service = ref.watch(exchangeRateReadyProvider);
  ref.watch(exchangeRateVersionProvider);
  if (bills.hasError) return AsyncError(bills.error!, bills.stackTrace!);
  if (categories.hasError) {
    return AsyncError(categories.error!, categories.stackTrace!);
  }
  if (!bills.hasValue ||
      !categories.hasValue ||
      bills.isLoading ||
      categories.isLoading) {
    return const AsyncLoading();
  }
  return AsyncData(
    buildCalendarReport(
      month: month,
      bills: bills.requireValue,
      categories: categories.requireValue,
      currency: view.code,
      quotes: view.isConverted ? FrozenCnyQuotes.capture(service.quote) : null,
    ),
  );
});

/// Includes cancelled fees, so old edit/delete paths cannot detach history.
final transferFeeProvider = StreamProvider.family<Bill?, String>(
  (ref, id) => ref.watch(databaseProvider).watchTransferFee(id),
);

final monthBillsProvider = StreamProvider<List<Bill>>((ref) {
  final m = ref.watch(selectedMonthProvider);
  final period = ReportPeriod.month(m);
  return ref
      .watch(databaseProvider)
      .watchBillsOfRange(period.startMs, period.endMs);
});

final aaGroupsProvider = StreamProvider<List<AaGroup>>(
  (ref) => ref.watch(databaseProvider).watchAaGroups(),
);

final settlementsProvider = StreamProvider<List<Settlement>>(
  (ref) => ref.watch(databaseProvider).watchSettlements(),
);

/// 已关联 AA 分摊组的账单 id 集合（判定伙伴账单是否已入账）
final linkedAaGroupIdsProvider = StreamProvider<Set<String>>(
  (ref) => ref.watch(databaseProvider).watchLinkedAaGroupIds(),
);
