import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_database.dart';
import 'sync/aa_sync_service.dart';
import 'utils/report_filter.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
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

/// Shared display currency for monthly summaries and existing charts.
/// Bills remain visible in their original currency; this never converts money.
class SelectedCurrencyNotifier extends Notifier<String> {
  @override
  String build() => 'CNY';

  void selectCurrency(String code) => state = code;
}

final selectedCurrencyProvider =
    NotifierProvider<SelectedCurrencyNotifier, String>(
      SelectedCurrencyNotifier.new,
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
