import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../utils/report_filter.dart';

/// 打开自定义日期范围选择器（明细页 AppBar 与范围条共用）。
/// 取消不改动当前选择与模式；确认写入范围并切换到范围模式。
/// 边界与账单录入一致（2000～2100）；首末日都包含，内部由
/// ReportDateRange 转为起日零点到结束日次日零点的左闭右开区间。
Future<void> showBillsRangePicker(BuildContext context, WidgetRef ref) async {
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
  final picked = await showDateRangePicker(
    context: context,
    initialDateRange: initial,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100, 12, 31),
    helpText: '选择自定义日期范围',
    confirmText: '确定',
    saveText: '确定',
  );
  if (picked == null) return; // 取消保留选择
  ref.read(selectedRangeProvider.notifier).select(
    ReportDateRange(start: picked.start, end: picked.end),
  );
  ref.read(billsPeriodModeProvider.notifier).select(BillsPeriodMode.range);
}

/// 自定义范围切换条（明细页范围模式）：‹ 起日 ~ 止日 ›，点击重新选择，
/// ‹ › 按范围天数平移；右侧按钮退出回按月（保留范围选择）。
class RangeBar extends ConsumerWidget {
  const RangeBar({super.key});

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
            onPressed: () => showBillsRangePicker(context, ref),
            child: Tooltip(
              message: '修改自定义范围',
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _rangeLabel(range),
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
          onPressed: () => ref
              .read(billsPeriodModeProvider.notifier)
              .select(BillsPeriodMode.month),
        ),
      ],
    );
  }
}

String _rangeLabel(ReportDateRange range) {
  final first = range.firstDay;
  final last = range.lastDay;
  if (first.year == last.year) {
    return '${first.year}年${first.month}月${first.day}日'
        ' ~ ${last.month}月${last.day}日';
  }
  return '${first.year}年${first.month}月${first.day}日'
      ' ~ ${last.year}年${last.month}月${last.day}日';
}
