import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'year_month_picker.dart';

/// 年份切换条（图表年报模式）：‹ 年份 › 与点击年份弹出年月选择器，
/// 仅采纳所选年份；状态存于 selectedYearProvider。
class YearBar extends ConsumerWidget {
  const YearBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final year = ref.watch(selectedYearProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: '上一年',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => ref.read(selectedYearProvider.notifier).shift(-1),
        ),
        Flexible(
          child: TextButton(
            key: const ValueKey('year-bar-select'),
            onPressed: () async {
              final picked = await showYearMonthPicker(
                context: context,
                initialMonth: DateTime(year, 1),
              );
              if (!context.mounted || picked == null) return;
              ref.read(selectedYearProvider.notifier).selectYear(picked.year);
            },
            child: Tooltip(
              message: '选择年份',
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$year年',
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
          tooltip: '下一年',
          icon: const Icon(Icons.chevron_right),
          onPressed: () => ref.read(selectedYearProvider.notifier).shift(1),
        ),
      ],
    );
  }
}
