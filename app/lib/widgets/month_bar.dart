import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../utils/money.dart';

/// 月份切换条（明细页 / 图表页共用，状态存于 selectedMonthProvider）
class MonthBar extends ConsumerWidget {
  const MonthBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(selectedMonthProvider);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () =>
              ref.read(selectedMonthProvider.notifier).shift(-1),
        ),
        Text(monthTitle(m),
            style:
                const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: () =>
              ref.read(selectedMonthProvider.notifier).shift(1),
        ),
      ],
    );
  }
}
