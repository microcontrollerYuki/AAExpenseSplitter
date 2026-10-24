import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../utils/money.dart';
import 'year_month_picker.dart';

/// 月份切换条。默认沿用明细/图表月份；日历可传入独立状态。
class MonthBar extends ConsumerWidget {
  const MonthBar({super.key, this.month, this.onSelect});

  final DateTime? month;
  final ValueChanged<DateTime>? onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime m = month ?? ref.watch<DateTime>(selectedMonthProvider);
    void select(DateTime value) {
      if (onSelect case final callback?) {
        callback(value);
      } else {
        ref.read(selectedMonthProvider.notifier).selectMonth(value);
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一月',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => select(DateTime(m.year, m.month - 1, 1)),
        ),
        Flexible(
          child: TextButton(
            key: const ValueKey('month-bar-select'),
            onPressed: () async {
              final picked = await showYearMonthPicker(
                context: context,
                initialMonth: m,
              );
              if (!context.mounted || picked == null) return;
              select(picked);
            },
            child: Tooltip(
              message: '选择年月',
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      monthTitle(m),
                      style: const TextStyle(
                        fontSize: 17,
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
          tooltip: '下一月',
          icon: const Icon(Icons.chevron_right),
          onPressed: () => select(DateTime(m.year, m.month + 1, 1)),
        ),
      ],
    );
  }
}
