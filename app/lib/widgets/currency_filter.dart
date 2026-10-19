import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../utils/currency.dart';

/// Only changes the displayed statistics; stored amounts are never converted.
/// [view] / [onSelect] carry the page's own [ReportViewCurrency] state so the
/// two report pages stay independent.
class CurrencyFilter extends StatelessWidget {
  const CurrencyFilter({
    super.key,
    required this.bills,
    required this.view,
    required this.onSelect,
  });

  final Iterable<Bill> bills;
  final ReportViewCurrency view;
  final void Function(ReportViewCurrency view) onSelect;

  @override
  Widget build(BuildContext context) {
    final codes = {
      for (final currency in Currency.values) currency.code,
      for (final bill in bills) bill.currency,
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
              child: PopupMenuButton<Object>(
                key: const ValueKey('currency-filter'),
                tooltip: '选择统计币种',
                initialValue: view,
                onSelected: (selected) {
                  if (selected is ReportViewCurrency) onSelect(selected);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: ReportViewCurrency.converted(),
                    child: Text('总览 · 折合 CNY'),
                  ),
                  for (final code in codes)
                    PopupMenuItem(
                      value: ReportViewCurrency.original(code),
                      child: Text(label(code)),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          view.isConverted ? '总览 · 折合 CNY' : label(view.code!),
                        ),
                      ),
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
