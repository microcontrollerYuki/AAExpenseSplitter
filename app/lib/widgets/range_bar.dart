import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../utils/report_filter.dart';

/// 打开自定义日期范围选择器，返回确认的范围；取消返回 null，不改动任何状态。
/// 边界与账单录入一致（2000～2100）；首末日都包含，内部由
/// ReportDateRange 转为起日零点到结束日次日零点的左闭右开区间。
Future<DateTimeRange?> pickDateRange(
  BuildContext context,
  WidgetRef ref,
) async {
  final current = ref.read(selectedRangeProvider);
  final anchor = ref.read(selectedMonthProvider);
  final DateTimeRange initial;
  if (current != null) {
    initial = DateTimeRange(start: current.firstDay, end: current.lastDay);
  } else {
    initial = DateTimeRange(
      start: DateTime(anchor.year, anchor.month),
      end: DateTime(anchor.year, anchor.month + 1, 0),
    );
  }
  final first = DateTime(2000);
  final last = DateTime(2100, 12, 31);
  DateTime bounded(DateTime date) =>
      date.isBefore(first) ? first : (date.isAfter(last) ? last : date);
  // Month selection and range shifting can exceed the picker's supported
  // years. Clamp only the picker draft; cancellation preserves stored state.
  final draft = DateTimeRange(
    start: bounded(initial.start),
    end: bounded(initial.end),
  );
  return showDateRangePicker(
    context: context,
    initialDateRange: draft,
    firstDate: first,
    lastDate: last,
    helpText: '选择自定义日期范围',
    confirmText: '确定',
    saveText: '确定',
  );
}

/// 明细页入口：确认后写入共享范围并切换明细页到范围模式。
Future<void> showBillsRangePicker(BuildContext context, WidgetRef ref) async {
  final picked = await pickDateRange(context, ref);
  if (picked == null || !context.mounted) return; // 取消或关闭保留选择
  ref
      .read(selectedRangeProvider.notifier)
      .select(ReportDateRange(start: picked.start, end: picked.end));
  ref.read(billsPeriodModeProvider.notifier).select(BillsPeriodMode.range);
}

/// 自定义范围切换条（明细页范围模式 / 图表页范围粒度共用）：
/// ‹ 起日 ~ 止日 ›，点击重新选择，‹ › 按范围天数平移；右侧按钮退出——
/// 默认回明细页按月，传入 [onExit] 时由调用方决定退出行为。
class RangeBar extends ConsumerWidget {
  const RangeBar({super.key, this.onExit, this.onRangeSelected});

  final VoidCallback? onExit;

  /// 图表页只更新共享范围，不切换明细页的周期模式。
  final ValueChanged<ReportDateRange>? onRangeSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(selectedRangeProvider);
    if (range == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '上一范围',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => ref
              .read(selectedRangeProvider.notifier)
              .select(range.shiftDays(-range.dayCount)),
        ),
        Flexible(
          child: TextButton(
            key: const ValueKey('range-bar-select'),
            onPressed: () async {
              if (onRangeSelected == null) {
                await showBillsRangePicker(context, ref);
                return;
              }
              final picked = await pickDateRange(context, ref);
              if (picked == null || !context.mounted) return;
              onRangeSelected!(
                ReportDateRange(start: picked.start, end: picked.end),
              );
            },
            child: Tooltip(
              message: '修改自定义范围',
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      reportDateRangeLabel(range),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: '下一范围',
          icon: const Icon(Icons.chevron_right),
          onPressed: () => ref
              .read(selectedRangeProvider.notifier)
              .select(range.shiftDays(range.dayCount)),
        ),
        IconButton(
          key: const ValueKey('range-bar-exit'),
          tooltip: '退出自定义范围',
          icon: const Icon(Icons.close),
          onPressed:
              onExit ??
              () => ref
                  .read(billsPeriodModeProvider.notifier)
                  .select(BillsPeriodMode.month),
        ),
      ],
    );
  }
}
