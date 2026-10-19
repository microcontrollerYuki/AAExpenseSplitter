import 'package:flutter/material.dart';

import '../exchange/exchange_rate_service.dart';
import '../utils/currency.dart';
import '../utils/report_conversion.dart';

/// 折合 CNY 视图的口径行：估算标识、数据时间、手动 / 过期状态与未纳入提示。
/// 只描述折算口径，不改动任何原币金额。
class ReportViewHint extends StatelessWidget {
  const ReportViewHint({super.key, required this.quotes, required this.excluded});

  final FrozenCnyQuotes quotes;
  final List<CnyExcludedCurrency> excluded;

  String _two(int v) => v.toString().padLeft(2, '0');

  String _time(DateTime utc) {
    final local = utc.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final parts = <String>['折合 CNY · 估算值'];
    final networkQuotes = Currency.values
        .map(quotes.quoteFor)
        .whereType<RateQuote>()
        .where((quote) => !quote.isManual && quote.base != Currency.cny)
        .toList();
    if (networkQuotes.isNotEmpty) {
      final latest = networkQuotes.reduce(
        (a, b) => b.fetchedAt.isAfter(a.fetchedAt) ? b : a,
      );
      parts
        ..add(latest.source)
        ..add('数据 ${_time(latest.fetchedAt)}');
    }
    final hasManual = Currency.values
        .map(quotes.quoteFor)
        .whereType<RateQuote>()
        .any((quote) => quote.isManual && quote.base != Currency.cny);
    if (hasManual) parts.add('含手动汇率');
    if (quotes.hasStale) parts.add('汇率已过期');
    if (excluded.isNotEmpty) {
      final excludedText = excluded
          .map((item) => '${item.code} ${item.count} 笔')
          .join('、');
      parts.add('未纳入 $excludedText');
    }
    final text = parts.join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Text(
        text,
        key: const ValueKey('report-view-hint'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
    );
  }
}
