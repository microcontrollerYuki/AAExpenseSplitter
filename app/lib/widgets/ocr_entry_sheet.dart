import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../data/presets.dart';
import '../recognition/bill_ocr.dart';
import '../theme.dart';
import '../utils/account_selection.dart';
import '../utils/currency.dart';
import '../utils/money.dart';
import 'category_picker.dart';
import 'currency_picker.dart';

/// 用户确认后的识别字段；采用只回填表单，不直接写入账本。
class OcrAdoptResult {
  const OcrAdoptResult({
    required this.amountText,
    required this.noteText,
    required this.currency,
    this.date,
    this.accountId,
    this.categoryId,
  });

  final String amountText;
  final String noteText;
  final Currency currency;
  final DateTime? date;
  final String? accountId;
  final String? categoryId;
}

/// 图片识别的可编辑确认面板。金额与币种确认后，跨币实际收付款额由主表单处理。
class OcrEntrySheet extends StatefulWidget {
  const OcrEntrySheet({
    super.key,
    required this.candidates,
    required this.initialAmount,
    required this.initialNote,
    this.initialCurrency,
    this.initialDate,
    this.initialAccountId,
    this.initialCategoryId,
    required this.accounts,
    required this.categories,
    required this.kind,
    required this.previewLines,
    this.cnyOnly = false,
  });

  final List<OcrMoneyCandidate> candidates;
  final String initialAmount;
  final String initialNote;
  final Currency? initialCurrency;
  final DateTime? initialDate;
  final String? initialAccountId;
  final String? initialCategoryId;
  final List<Account> accounts;
  final List<Category> categories;
  final int kind;
  final List<String> previewLines;
  final bool cnyOnly;

  @override
  State<OcrEntrySheet> createState() => _OcrEntrySheetState();
}

class _OcrEntrySheetState extends State<OcrEntrySheet> {
  late final _amountCtl = TextEditingController(text: widget.initialAmount);
  late final _noteCtl = TextEditingController(text: widget.initialNote);
  late Currency? _currency = widget.initialCurrency;
  late DateTime? _selDate = widget.initialDate;
  late String? _selAccId = widget.initialAccountId;
  late String? _selCatId = widget.initialCategoryId;
  String? _error;

  List<Account> get _accounts => widget.accounts.where((account) {
    if (Currency.tryFromCode(account.currency) == null) return false;
    if (widget.cnyOnly && account.currency != 'CNY') return false;
    if (account.type == 4 || account.id == kAaCreditAccountId) {
      return account.id == kAaCreditAccountId && _currency == Currency.cny;
    }
    return true;
  }).toList();

  Account? get _accObj =>
      _accounts.where((account) => account.id == _selAccId).firstOrNull;

  Category? get _catObj => widget.categories
      .where((category) => category.id == _selCatId)
      .firstOrNull;

  @override
  void dispose() {
    _amountCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  void _setCurrency(Currency? currency) {
    _currency = currency;
    _error = null;
    if (_selAccId != null && _accObj == null) _selAccId = null;
  }

  void _adopt() {
    final currency = _currency;
    if (currency == null) {
      setState(() => _error = '请选择并确认币种');
      return;
    }
    if (widget.cnyOnly && currency != Currency.cny) {
      setState(() => _error = 'AA 和转账暂仅支持人民币，请选择 CNY');
      return;
    }
    final units = parseMoneyToMinorUnits(_amountCtl.text, currency);
    if (units == null || units <= 0) {
      setState(
        () => _error = currency == Currency.jpy
            ? 'JPY 金额必须为正整数'
            : '${currency.code} 金额必须大于 0，最多支持两位小数',
      );
      return;
    }
    if (_selAccId != null && _accObj == null) {
      setState(() => _error = staleEntryAccountMessage);
      return;
    }
    Navigator.pop(
      context,
      OcrAdoptResult(
        amountText: formatMinorUnits(units, currency, grouping: false),
        noteText: _noteCtl.text.trim(),
        currency: currency,
        date: _selDate,
        accountId: _selAccId,
        categoryId: _selCatId,
      ),
    );
  }

  String _fmtDate(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  Future<void> _pickDate() async {
    FocusScope.of(context).unfocus();
    final base = _selDate ?? DateTime.now();
    final first = DateTime(2000);
    final last = DateTime(2100, 12, 31);
    final initial = base.isBefore(first)
        ? first
        : base.isAfter(last)
        ? last
        : base;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (!mounted) return;
    setState(
      () => _selDate = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time?.hour ?? base.hour,
        time?.minute ?? base.minute,
      ),
    );
  }

  Future<void> _pickAccount() async {
    FocusScope.of(context).unfocus();
    final accounts = _accounts;
    final id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.6,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '选择账户',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    if (accounts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          widget.cnyOnly
                              ? noCnyAccountMessage
                              : noEntryAccountMessage,
                        ),
                      ),
                    for (final account in accounts)
                      ListTile(
                        leading: Text(
                          account.emoji,
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(account.name),
                        subtitle: Text(account.currency),
                        onTap: () => Navigator.pop(sheetContext, account.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (id == null || !mounted) return;
    setState(() {
      _selAccId = id;
      _error = null;
    });
  }

  Future<void> _pickCategory() async {
    FocusScope.of(context).unfocus();
    final id = await showCategoryPicker(
      context: context,
      categories: widget.categories,
      kind: widget.kind,
      selectedId: _selCatId,
    );
    if (id == null || !mounted) return;
    setState(() => _selCatId = id);
  }

  @override
  Widget build(BuildContext context) {
    final account = _accObj;
    final category = _catObj;
    final media = MediaQuery.of(context);
    final available =
        (media.size.height -
                media.viewInsets.bottom -
                media.padding.top -
                media.padding.bottom)
            .clamp(0.0, media.size.height)
            .toDouble();
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: available * 0.9),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '图片识别结果',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ActionChip(
                  key: const ValueKey('ocr-currency'),
                  label: Text(
                    _currency == null
                        ? '币种待确认'
                        : '${_currency!.code} ${_currency!.displayName}',
                  ),
                  onPressed: () async {
                    FocusScope.of(context).unfocus();
                    final currency = await showEntryCurrencyPicker(
                      context,
                      selected: _currency,
                      cnyOnly: widget.cnyOnly,
                    );
                    if (currency == null || !mounted) return;
                    setState(() => _setCurrency(currency));
                  },
                ),
                TextField(
                  key: const ValueKey('ocr-amount-input'),
                  controller: _amountCtl,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: _currency != Currency.jpy,
                  ),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: const InputDecoration(
                    hintText: '输入金额',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
                if (widget.candidates.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final candidate in widget.candidates.take(8))
                        ActionChip(
                          label: Text(
                            '${candidate.currency?.code ?? '币种待确认'} '
                            '${candidate.amountText}',
                          ),
                          onPressed: () => setState(() {
                            _amountCtl.text = candidate.amountText;
                            _setCurrency(candidate.currency);
                          }),
                        ),
                    ],
                  ),
                if (_currency == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      '符号或数字无法确定币种，请手动确认',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ),
                const Divider(height: 20),
                _row(
                  Icons.schedule,
                  '日期',
                  _selDate == null ? '使用当前时间' : _fmtDate(_selDate!),
                  _pickDate,
                ),
                TextField(
                  key: const ValueKey('ocr-note-input'),
                  controller: _noteCtl,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: '备注（在哪里消费？）',
                    prefixIcon: Icon(Icons.edit_note, size: 20),
                    isDense: true,
                  ),
                ),
                _row(
                  Icons.account_balance_wallet,
                  '账户',
                  account == null
                      ? (_accounts.isEmpty
                            ? (widget.cnyOnly
                                  ? noCnyAccountMessage
                                  : noEntryAccountMessage)
                            : '保持当前选择')
                      : '${account.emoji} ${account.name} · ${account.currency}',
                  _pickAccount,
                ),
                _row(
                  Icons.category,
                  '分类',
                  category == null
                      ? '未选择'
                      : '${category.emoji} '
                            '${CategoryHierarchy(widget.categories).pathOf(category.id)}',
                  _pickCategory,
                ),
                const Divider(height: 20),
                const Text(
                  '识别文本预览：',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 110),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final line in widget.previewLines.take(12))
                        Text(
                          line,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.black45,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      key: const ValueKey('ocr-error'),
                      style: const TextStyle(color: kExpenseColor),
                    ),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kPrimaryColor,
                    ),
                    onPressed: _adopt,
                    child: const Text('采用并填入'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(
    IconData icon,
    String label,
    String value,
    VoidCallback onTap,
  ) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
        ],
      ),
    ),
  );
}
