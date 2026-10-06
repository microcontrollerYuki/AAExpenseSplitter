import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/presets.dart';
import '../providers.dart';
import '../theme.dart';
import '../utils/balance.dart';
import '../utils/money.dart';

/// 账本页：总资产 + 账户列表（增改删）
class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final bills = ref.watch(allBillsProvider).value ?? const <Bill>[];
    final balances = computeBalances(accounts, bills);
    var netWorth = 0;
    for (final a in accounts) {
      if (a.includeNetWorth) netWorth += balances[a.id] ?? 0;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('账本'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加账户',
            onPressed: () =>
                _openEdit(context, ref.read(databaseProvider), null, accounts.length),
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
                const Text('总资产（计入净资产的账户）',
                    style: TextStyle(fontSize: 12, color: Colors.white70)),
                const SizedBox(height: 6),
                Text('¥ ${centsToText(netWorth)}',
                    style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
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
                      child: Text(a.emoji,
                          style: const TextStyle(fontSize: 20)),
                    ),
                    title: Text(a.name),
                    subtitle: Text(
                      kAccountTypeNames[a.type],
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Text(
                      centsToText(balances[a.id] ?? 0),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: (balances[a.id] ?? 0) < 0
                            ? kExpenseColor
                            : Colors.black87,
                      ),
                    ),
                    onTap: () => _openEdit(
                        context, ref.read(databaseProvider), a, accounts.length),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('点击账户可编辑；仍有账单关联的账户无法删除',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  void _openEdit(
      BuildContext context, AppDatabase db, Account? acc, int accountCount) {
    showDialog(
      context: context,
      builder: (_) => _AccountDialog(
          db: db, account: acc, newSort: accountCount),
    );
  }
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({
    required this.db,
    this.account,
    required this.newSort,
  });

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

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _nameCtl = TextEditingController(text: a?.name ?? '');
    _balanceCtl = TextEditingController(
        text: a == null ? '' : centsToText(a.initBalance));
    _emoji = a?.emoji ?? kAccountEmojiChoices.first;
    _include = a?.includeNetWorth ?? true;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _balanceCtl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    try {
      debugPrint('[AccountDialog] save pressed, name=${_nameCtl.text}');
      final name = _nameCtl.text.trim();
      if (name.isEmpty) {
        _snack('请填写账户名称');
        return;
      }
      final id =
          widget.account?.id ?? 'acc_${const Uuid().v4().substring(0, 8)}';
      await widget.db.upsertAccount(
        id: id,
        name: name,
        emoji: _emoji,
        type: widget.account?.type ?? 3,
        initBalance: parseMoneyToCents(_balanceCtl.text),
        includeNetWorth: _include,
        sort: widget.account?.sort ?? widget.newSort,
      );
      debugPrint('[AccountDialog] saved ok, closing');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      debugPrint('[AccountDialog] save error: $e');
      if (mounted) _snack('保存失败：$e');
    }
  }

  Future<void> _delete() async {
    final a = widget.account;
    if (a == null) return;
    final n = await widget.db.billCountOfAccount(a.id);
    if (n > 0) {
      _snack('该账户已有 $n 笔账单，无法删除');
      return;
    }
    await widget.db.deleteAccount(a.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // 键盘避让由 AlertDialog 内置的 AnimatedPadding(viewInsets) 处理，
    // 不要在外层再包一层避让（双倍内边距会把弹窗顶飞且布局震荡）
    return AlertDialog(
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
                        child:
                            Text(e, style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _balanceCtl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [_MoneyInputFormatter()],
                decoration:
                    const InputDecoration(labelText: '期初余额（元）'),
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
        if (widget.account != null)
          TextButton(
            onPressed: _delete,
            child:
                const Text('删除', style: TextStyle(color: kExpenseColor)),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

/// 金额输入格式化：整数部分千分位分组（1000000 → 1,000,000），最多两位小数
class _MoneyInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text.replaceAll(',', '');
    if (raw.isEmpty) {
      return const TextEditingValue(text: '');
    }
    if (!RegExp(r'^\d{0,12}(\.\d{0,2})?$').hasMatch(raw)) {
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
    for (var i = 0; i < s.length; i++) {
      final remain = s.length - i;
      sb.write(s[i]);
      if (remain > 1 && remain % 3 == 1) sb.write(',');
    }
    return sb.toString();
  }
}
