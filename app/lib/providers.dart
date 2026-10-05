import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_database.dart';
import 'sync/aa_sync_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final aaSyncServiceProvider =
    Provider<AaSyncService>((ref) => AaSyncService(ref.watch(databaseProvider)));

/// 配对信息与本机键值（myUid / myName / partnerName / pairSecret / 同步时间）
final metaProvider = StreamProvider<Map<String, String>>((ref) => ref
    .watch(databaseProvider)
    .watchMeta()
    .map((rows) => {for (final r in rows) r.key: r.value}));

/// 全局选中的月份（明细页 / 图表页共享），1 号作为锚点
class SelectedMonthNotifier extends Notifier<DateTime> {
  @override
  DateTime build() => DateTime.now();

  void shift(int delta) => state = DateTime(state.year, state.month + delta, 1);
}

final selectedMonthProvider =
    NotifierProvider<SelectedMonthNotifier, DateTime>(SelectedMonthNotifier.new);

final accountsProvider = StreamProvider<List<Account>>(
    (ref) => ref.watch(databaseProvider).watchAccounts());

final categoriesProvider = StreamProvider<List<Category>>(
    (ref) => ref.watch(databaseProvider).watchCategories());

final allBillsProvider =
    StreamProvider<List<Bill>>((ref) => ref.watch(databaseProvider).watchAllBills());

final monthBillsProvider = StreamProvider<List<Bill>>((ref) {
  final m = ref.watch(selectedMonthProvider);
  final start = DateTime(m.year, m.month, 1).millisecondsSinceEpoch;
  final end = DateTime(m.year, m.month + 1, 1).millisecondsSinceEpoch;
  return ref.watch(databaseProvider).watchBillsOfRange(start, end);
});

final aaGroupsProvider = StreamProvider<List<AaGroup>>(
    (ref) => ref.watch(databaseProvider).watchAaGroups());

final settlementsProvider = StreamProvider<List<Settlement>>(
    (ref) => ref.watch(databaseProvider).watchSettlements());
