import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/presets.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/balance.dart';
import '../utils/currency.dart';
import '../utils/money.dart';
import 'account_info_page.dart';

/// 账本页：总资产 + 账户列表（增改删）
class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final bills = ref.watch(allBillsProvider).value ?? const <Bill>[];
    final balances = computeExactBalances(accounts, bills);
    final netWorth = computeExactNetWorthByCurrency(accounts, balances);

    return Scaffold(
      appBar: AppBar(
        title: const Text('账本'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加账户',
            onPressed: () => showAccountEditor(
              context,
              ref.read(databaseProvider),
              account: null,
              newSort: accounts.length,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF2E7D5B), Color(0xFF4C9A6E)],
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '总资产（计入净资产的账户）',
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 6),
                if (netWorth.isEmpty)
                  const Text(
                    '暂无计入总资产的账户',
                    style: TextStyle(color: Colors.white),
                  ),
                for (final entry in netWorth.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Text(
                          Currency.tryFromCode(entry.key)?.displayName ??
                              '未知币种',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              _accountMoney(entry.value, entry.key),
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final a in accounts)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.grey.shade100,
                      child: Text(
                        a.emoji,
                        style: const TextStyle(fontSize: 20),
                      ),
                    ),
                    title: Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Wrap(
                      children: [
                        Text(
                          kAccountTypeNames[a.type],
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          ' · ${a.currency}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    trailing: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * 0.45,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _accountMoney(
                            balances[a.id] ?? BigInt.zero,
                            a.currency,
                            showCode: false,
                          ),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: (balances[a.id] ?? BigInt.zero).isNegative
                                ? kExpenseColor
                                : Colors.black87,
                          ),
                        ),
                      ),
                    ),
                    // 点击进入账户信息页（余额 + 动账明细），「修改」才打开编辑弹窗
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AccountInfoPage(account: a),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '点击账户查看余额与动账明细；仍有账单关联的账户无法删除',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

String _accountMoney(BigInt amount, String code, {bool showCode = true}) {
  final currency = Currency.tryFromCode(code);
  if (currency == null) return '$code $amount（最小单位）';
  final text = formatBigMinorUnits(amount, currency);
  if (!showCode) return text;
  return currency == Currency.cny ? '¥ $text' : '${currency.code} $text';
}

/// 打开账户编辑弹窗（新建 account 传 null）：账本「+」与账户信息页「修改」共用。
/// 返回 true 表示执行了删除
Future<bool?> showAccountEditor(
  BuildContext context,
  AppDatabase db, {
  Account? account,
  required int newSort,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _AccountDialog(db: db, account: account, newSort: newSort),
  );
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({required this.db, this.account, required this.newSort});

  final AppDatabase db;
  final Account? account;
  final int newSort;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _balanceCtl;
  late String _emoji;
  late bool _include;
  late Currency? _currency;
  bool _checkingCurrency = false;
  bool _currencyLocked = false;
  int _referenceCount = 0;
  bool _saving = false;
  String? _balanceError;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _nameCtl = TextEditingController(text: a?.name ?? '');
    _currency = a == null ? Currency.cny : Currency.tryFromCode(a.currency);
    _balanceCtl = TextEditingController(
      text: a == null
          ? ''
          : _accountMoney(
              BigInt.from(a.initBalance),
              a.currency,
              showCode: false,
            ),
    );
    _emoji = a?.emoji ?? kAccountEmojiChoices.first;
    _include = a?.includeNetWorth ?? true;
    if (a != null) {
      _checkingCurrency = true;
      _currencyLocked = a.type == 4 || a.id == kAaCreditAccountId;
      _loadCurrencyLock();
    }
  }

  Future<void> _loadCurrencyLock() async {
    try {
      final count = await widget.db.billCountOfAccount(
        widget.account!.id,
        includeDeleted: true,
      );
      if (!mounted) return;
      setState(() {
        _referenceCount = count;
        _currencyLocked = _currencyLocked || count > 0;
        _checkingCurrency = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = '账户引用读取失败，请关闭后重试';
        _checkingCurrency = false;
        _currencyLocked = true;
      });
    }
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _balanceCtl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 资产名称规范化（仅用于重名判定）：去空白、忽略大小写、去掉开头的
  /// 「AA」类前缀（AA-现金 / AA_现金 / AA·现金 / AA现金 与「现金」视为重名）
  static String _normAssetName(String s) {
    final v = s.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    return v.replaceFirst(RegExp(r'^aa[-_.·—－]?\s*(?=[\u4e00-\u9fa5])'), '');
  }

  Future<void> _save() async {
    if (_saving || _checkingCurrency || _loadError != null) return;
    try {
      final name = _nameCtl.text.trim();
      if (name.isEmpty) {
        _snack('请填写账户名称');
        return;
      }
      final currency = _currency;
      if (currency == null) {
        _snack('请选择支持的账户币种');
        return;
      }
      final balance = _balanceCtl.text.trim().isEmpty
          ? 0
          : parseMoneyToMinorUnits(_balanceCtl.text, currency);
      if (balance == null) {
        setState(
          () => _balanceError = currency == Currency.jpy
              ? '日元期初余额须为整数，且在支持范围内'
              : '请输入有效期初余额，最多两位小数且在支持范围内',
        );
        return;
      }
      setState(() {
        _saving = true;
        _balanceError = null;
      });
      // 不允许重名资产（含 AA-现金 / AA-银行卡 这类带前缀的变体重名）
      final norm = _normAssetName(name);
      final currentId = widget.account?.id;
      for (final a in await widget.db.getAllAccounts()) {
        if (a.id == currentId) continue;
        if (_normAssetName(a.name) == norm) {
          _snack('已有同名账户，不允许重名');
          return;
        }
      }
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      final id =
          widget.account?.id ?? 'acc_${const Uuid().v4().substring(0, 8)}';
      await widget.db.upsertAccount(
        id: id,
        name: name,
        emoji: _emoji,
        type: widget.account?.type ?? 3,
        initBalance: balance,
        currency: currency.code,
        expected: widget.account,
        includeNetWorth: _include,
        sort: widget.account?.sort ?? widget.newSort,
      );
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) _snack('保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final a = widget.account;
    if (a == null) return;
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final n = await widget.db.billCountOfAccount(a.id, includeDeleted: true);
      if (n > 0) {
        _snack('该账户已有 $n 笔账单，无法删除（含已删除账单）');
        return;
      }
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      await widget.db.deleteAccount(a.id);
      // pop(true) 通知调用方（账户信息页）已删除，用于返回列表
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      _snack('删除失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 键盘避让由 AlertDialog 内置的 AnimatedPadding(viewInsets) 处理，
    // 不要在外层再包一层避让（双倍内边距会把弹窗顶飞且布局震荡）
    return PopScope<bool>(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.account == null ? '添加账户' : '编辑账户'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _nameCtl,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final e in kAccountEmojiChoices)
                      GestureDetector(
                        onTap: () => setState(() => _emoji = e),
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: _emoji == e
                              ? kPrimaryColor.withValues(alpha: 0.18)
                              : Colors.grey.shade100,
                          child: Text(e, style: const TextStyle(fontSize: 18)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<Currency>(
                  key: const ValueKey('account_currency'),
                  initialValue: _currency,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '币种',
                    helperText: _checkingCurrency
                        ? '正在检查账户引用…'
                        : _referenceCount > 0
                        ? '已有账单引用（含已删除），币种不可修改'
                        : _currencyLocked
                        ? 'AA挂账固定使用 CNY'
                        : '期初余额按所选币种填写，不自动换算',
                    helperMaxLines: 2,
                    errorText: _loadError,
                  ),
                  hint: Text('不支持的币种：${widget.account?.currency ?? ''}'),
                  items: [
                    for (final currency in Currency.values)
                      DropdownMenuItem(
                        value: currency,
                        child: Text(
                          '${currency.code} · ${currency.displayName}',
                        ),
                      ),
                  ],
                  onChanged: _currencyLocked || _checkingCurrency || _saving
                      ? null
                      : (value) => setState(() {
                          _currency = value;
                          _balanceError = null;
                        }),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _balanceCtl,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: _currency != Currency.jpy,
                    signed: true,
                  ),
                  inputFormatters: [
                    _MoneyInputFormatter(_currency?.minorUnitDigits ?? 2),
                  ],
                  decoration: InputDecoration(
                    labelText: _currency == Currency.cny
                        ? '期初余额（元）'
                        : '期初余额（${_currency?.code ?? widget.account?.currency ?? ''}）',
                    errorText: _balanceError,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('计入总资产'),
                  value: _include,
                  onChanged: (v) => setState(() => _include = v),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (widget.account != null &&
              widget.account!.id != kAaCreditAccountId)
            TextButton(
              onPressed: _saving ? null : _delete,
              child: const Text('删除', style: TextStyle(color: kExpenseColor)),
            ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _saving || _checkingCurrency || _loadError != null
                ? null
                : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ],
      ),
    );
  }
}

/// 金额输入格式化：整数部分千分位分组（1000000 → 1,000,000），最多两位小数
class _MoneyInputFormatter extends TextInputFormatter {
  _MoneyInputFormatter(this.precision);
  final int precision;
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text.replaceAll(',', '');
    if (raw.isEmpty) {
      return const TextEditingValue(text: '');
    }
    if (!RegExp(r'^-?\d{0,19}(\.\d{0,2})?$').hasMatch(raw)) {
      return oldValue;
    }
    final fractionLength = raw.contains('.') ? raw.split('.').last.length : 0;
    final tooPrecise =
        fractionLength > precision || (precision == 0 && raw.contains('.'));
    if (tooPrecise && raw.length >= oldValue.text.replaceAll(',', '').length) {
      return oldValue;
    }
    final dot = raw.indexOf('.');
    final intPart = dot < 0 ? raw : raw.substring(0, dot);
    final decPart = dot < 0 ? '' : raw.substring(dot);
    final grouped = _group(intPart);
    final formatted = dot < 0 ? grouped : '$grouped$decPart';

    // 光标映射：按光标前的有效字符数（不含逗号）在新文本中定位
    final sel = newValue.selection.start < 0
        ? newValue.text.length
        : newValue.selection.start;
    var effective = 0;
    for (var i = 0; i < sel && i < newValue.text.length; i++) {
      if (newValue.text[i] != ',') effective++;
    }
    var pos = 0;
    var counted = 0;
    while (pos < formatted.length && counted < effective) {
      if (formatted[pos] != ',') counted++;
      pos++;
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: pos),
    );
  }

  String _group(String s) {
    final sb = StringBuffer();
    if (s.startsWith('-')) {
      sb.write('-');
      s = s.substring(1);
    }
    for (var i = 0; i < s.length; i++) {
      final remain = s.length - i;
      sb.write(s[i]);
      if (remain > 1 && remain % 3 == 1) sb.write(',');
    }
    return sb.toString();
  }
}
