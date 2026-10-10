import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../utils/money.dart';
import 'year_month_picker.dart';

/// 月份切换条（明细页 / 图表页共用，状态存于 selectedMonthProvider）
class MonthBar extends ConsumerWidget {
  const MonthBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(selectedMonthProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一月',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => ref.read(selectedMonthProvider.notifier).shift(-1),
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
              ref.read(selectedMonthProvider.notifier).selectMonth(picked);
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
          onPressed: () => ref.read(selectedMonthProvider.notifier).shift(1),
        ),
      ],
    );
  }
}
