import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../exchange/exchange_rate.dart';
import '../exchange/exchange_rate_service.dart';
import '../providers.dart';
import '../utils/currency.dart';

class ExchangeRatesPage extends ConsumerStatefulWidget {
  const ExchangeRatesPage({super.key});

  @override
  ConsumerState<ExchangeRatesPage> createState() => _ExchangeRatesPageState();
}

class _ExchangeRatesPageState extends ConsumerState<ExchangeRatesPage> {
  Currency _base = Currency.usd;
  Currency _quote = Currency.cny;
  late final ExchangeRateService _service;
  bool _manualOpen = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(exchangeRateServiceProvider);
    _service.initialize();
  }

  Future<void> _editManual() async {
    if (_manualOpen || _service.saving || _base == _quote) return;
    _manualOpen = true;
    final base = _base;
    final quote = _quote;
    bool? saved;
    try {
      saved = await showDialog<bool>(
        context: context,
        builder: (_) =>
            _ManualRateDialog(service: _service, base: base, quote: quote),
      );
    } finally {
      _manualOpen = false;
    }
    if (!mounted || saved != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存 ${base.code} → ${quote.code} 手动汇率')),
    );
  }

  Future<void> _useNetwork() async {
    if (_service.saving) return;
    try {
      await _service.useNetwork(_base, _quote);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已恢复网络模式，请查看当前汇率状态')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_service.error ?? '恢复失败，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('汇率设置')),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final rate = _service.quote(_base, _quote);
          final sameCurrency = _base == _quote;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                '联网汇率来自 Frankfurter / ECB 每日参考数据，'
                '并非实时成交汇率。可手动设置指定币对。',
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: _currencyField(base: true)),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(Icons.arrow_forward),
                  ),
                  Expanded(child: _currencyField(base: false)),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (sameCurrency)
                        Text(
                          '1 ${_base.code} = 1 ${_quote.code}',
                          key: const Key('rate-value'),
                          style: Theme.of(context).textTheme.titleLarge,
                        )
                      else if (rate != null)
                        Text(
                          '1 ${_base.code} ≈ '
                          '${rate.ratio.toDecimalString(fractionDigits: 18)} '
                          '${_quote.code}',
                          key: const Key('rate-value'),
                          style: Theme.of(context).textTheme.titleLarge,
                        )
                      else
                        const Text('暂无可用汇率', key: Key('rate-value')),
                      const SizedBox(height: 12),
                      if (sameCurrency)
                        const Text('同币种汇率固定为 1，无需设置。')
                      else if (rate != null) ...[
                        Text('来源：${rate.source}'),
                        if (rate.isManual)
                          Text('手动更新时间：${_timeText(rate.quotedAt)}')
                        else ...[
                          Text('报价日期：${_dateText(rate.quotedAt)}'),
                          Text('获取时间：${_timeText(rate.fetchedAt)}'),
                          Text(
                            rate.isStale
                                ? '网络缓存已过期，请刷新或手动设置。'
                                : '当前使用已获取的网络参考汇率。',
                            key: const Key('rate-cache-status'),
                          ),
                        ],
                        const SizedBox(height: 8),
                        const Text('≈ 为显示约值，计算使用完整精度。'),
                      ] else
                        const Text('可联网刷新，或为该币对设置手动汇率。'),
                    ],
                  ),
                ),
              ),
              if (_service.cacheCorrupt) ...[
                const SizedBox(height: 12),
                const _RateNotice(
                  key: Key('rate-cache-corrupt'),
                  text: '本地汇率缓存损坏，未采用其中的数值。请联网刷新或重新设置手动汇率。',
                ),
              ],
              if (_service.error != null) ...[
                const SizedBox(height: 12),
                _RateNotice(
                  key: const Key('rate-error'),
                  text:
                      '${_service.error}'
                      '${rate != null && !rate.isManual && !sameCurrency ? '\n继续显示已有网络缓存；请留意报价日期与缓存状态。' : ''}',
                ),
              ],
              const SizedBox(height: 16),
              if (_service.loading)
                Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('正在获取网络汇率…')),
                    TextButton(
                      key: const Key('rate-cancel'),
                      onPressed: _service.cancelRefresh,
                      child: const Text('取消'),
                    ),
                  ],
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('rate-refresh'),
                    onPressed: _service.loading || _service.saving
                        ? null
                        : _service.refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('联网刷新'),
                  ),
                  OutlinedButton(
                    key: const Key('rate-manual-edit'),
                    onPressed: sameCurrency || _service.saving
                        ? null
                        : _editManual,
                    child: const Text('手动设置'),
                  ),
                  if (rate?.isManual == true && !sameCurrency)
                    TextButton(
                      key: const Key('rate-use-network'),
                      onPressed: _service.saving ? null : _useNetwork,
                      child: const Text('恢复网络汇率'),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                '手动设置仅作用于当前币对及其反向，不影响其他币对。'
                '联网刷新会更新网络缓存，并保留手动设置。',
              ),
              const SizedBox(height: 16),
              const Text(
                '当前汇率设置尚未用于自动填写转账或折算报表，'
                '这两项将在后续更新接入。',
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _currencyField({required bool base}) {
    return DropdownButtonFormField<Currency>(
      key: Key(base ? 'rate-base' : 'rate-quote'),
      initialValue: base ? _base : _quote,
      isExpanded: true,
      decoration: InputDecoration(labelText: base ? '原币种' : '目标币种'),
      items: [
        for (final currency in Currency.values)
          DropdownMenuItem(value: currency, child: Text(currency.code)),
      ],
      onChanged: _service.saving
          ? null
          : (value) {
              if (value == null) return;
              setState(() {
                if (base) {
                  _base = value;
                } else {
                  _quote = value;
                }
              });
            },
    );
  }
}

class _RateNotice extends StatelessWidget {
  const _RateNotice({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text),
    );
  }
}

class _ManualRateDialog extends StatefulWidget {
  const _ManualRateDialog({
    required this.service,
    required this.base,
    required this.quote,
  });

  final ExchangeRateService service;
  final Currency base;
  final Currency quote;

  @override
  State<_ManualRateDialog> createState() => _ManualRateDialogState();
}

class _ManualRateDialogState extends State<_ManualRateDialog> {
  final _controller = TextEditingController();
  bool _saving = false;
  bool _closed = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _closed || widget.service.saving) return;
    final input = _controller.text.trim();
    try {
      if (!RegExp(r'^(?:\d+(?:\.\d{1,18})?|\.\d{1,18})$').hasMatch(input)) {
        throw const FormatException('请输入正十进制数，最多 18 位小数，不支持科学计数法');
      }
      RateRatio.parse(input);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.setManual(widget.base, widget.quote, input);
      if (!mounted || _closed) return;
      _closed = true;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = widget.service.error ?? '保存失败，请重试';
      });
    }
  }

  void _cancel() {
    if (_saving || _closed) return;
    _closed = true;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('手动设置汇率'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1 ${widget.base.code} = 多少 ${widget.quote.code}？'),
              const SizedBox(height: 12),
              TextField(
                key: const Key('rate-manual-input'),
                controller: _controller,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: widget.quote.code,
                  errorText: _error,
                  errorMaxLines: 4,
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              const Text(
                '请输入大于零的十进制数，最多 18 位小数。'
                '仅覆盖此币对及反向，取消不会保存。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('rate-manual-cancel'),
            onPressed: _saving ? null : _cancel,
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('rate-manual-save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ],
      ),
    );
  }
}

String _dateText(DateTime value) =>
    '${value.year}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _timeText(DateTime value) {
  final local = value.toLocal();
  return '${_dateText(local)} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}:'
      '${local.second.toString().padLeft(2, '0')}';
}
