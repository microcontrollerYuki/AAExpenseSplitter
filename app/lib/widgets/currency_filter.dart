import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../utils/currency.dart';

/// Only changes the displayed statistics; stored amounts are never converted.
class CurrencyFilter extends ConsumerWidget {
  const CurrencyFilter({super.key, required this.bills});

  final Iterable<Bill> bills;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedCurrencyProvider);
    final codes = {
      for (final currency in Currency.values) currency.code,
      for (final bill in bills) bill.currency,
      selected,
    };
    String label(String code) {
      final currency = Currency.tryFromCode(code);
      return currency == null
          ? '${code.trim().isEmpty ? '未知币种' : code}（最小单位）'
          : '${currency.displayName} $code';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Text(
            '统计币种',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: PopupMenuButton<String>(
                key: const ValueKey('currency-filter'),
                tooltip: '选择统计币种',
                initialValue: selected,
                onSelected: ref
                    .read(selectedCurrencyProvider.notifier)
                    .selectCurrency,
                itemBuilder: (_) => [
                  for (final code in codes)
                    PopupMenuItem(value: code, child: Text(label(code))),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(label(selected))),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
