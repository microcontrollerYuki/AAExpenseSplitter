import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../data/presets.dart';
import '../providers.dart';
import '../recognition/bill_ocr.dart';
import '../sync/aa_sync_service.dart';
import '../theme.dart';
import '../utils/account_selection.dart';
import '../utils/bill_money.dart';
import '../utils/currency.dart';
import '../utils/money.dart';
import '../utils/money_expression.dart';
import '../widgets/category_picker.dart';
import '../widgets/currency_picker.dart';
import '../widgets/number_pad.dart';
import '../widgets/ocr_entry_sheet.dart';
import 'categories_page.dart';

/// 记账 / 编辑账单页（钱迹风格布局）：
/// 顶部类型页签 + 分层分类宫格 + 原币金额 / 账户实际额 / 计算键盘。
class EditBillPage extends ConsumerStatefulWidget {
  const EditBillPage({super.key, this.bill});

  final Bill? bill;

  @override
  ConsumerState<EditBillPage> createState() => _EditBillPageState();
}

class _EditBillPageState extends ConsumerState<EditBillPage> {
  late int _type; // 0 支出 / 1 收入 / 2 转账
  String _amount = ''; // 支持表达式，如 12+3.5
  String? _categoryId;
  String? _accountId;
  String? _toAccountId;
  late DateTime _date;
  late final TextEditingController _noteCtl;
  bool _aaOn = false;
  bool _savingSettlement = false;
  bool _saving = false;
  Currency _currency = Currency.cny;
  int? _actualAmount;
  String? _actualSignature;
  bool _originalActual = false;
  int? _receivedAmount;
  String? _receivedSignature;
  bool _originalReceived = false;
  bool _requireReceivedConfirmation = false;

  bool get _aaRestricted => _aaOn || widget.bill?.aaGroupId != null;

  List<Account> _entryAccounts(Iterable<Account> accounts) => _type == 2
      ? transferEntryAccounts(accounts)
      : _isSettlementEdit
      ? cnyEntryAccounts(accounts, includeAaCredit: false)
      : bookkeepingEntryAccounts(accounts, _currency, cnyOnly: _aaRestricted);

  String? _effectiveAccountId(List<Account> accounts) => _type == 2
      ? entryAccountId(accounts, _accountId)
      : bookkeepingAccountId(accounts, _accountId, _currency);

  void _invalidateActual() {
    _actualAmount = null;
    _actualSignature = null;
    _originalActual = false;
    _receivedAmount = null;
    _receivedSignature = null;
    _originalReceived = false;
  }

  String _transferSignature(Account source, Account target, int units) =>
      '$_type|${source.id}|${source.currency}|${target.id}|${target.currency}|$units';

  bool _receivedConfirmed(Account source, Account target, int units) {
    final b = widget.bill;
    return _receivedAmount != null &&
        (_receivedSignature == _transferSignature(source, target, units) ||
            (_originalReceived &&
                b != null &&
                b.type == 2 &&
                _type == 2 &&
                b.accountId == source.id &&
                b.toAccountId == target.id &&
                b.currency == source.currency &&
                b.amount == units &&
                b.accountAmount == units));
  }

  bool _unsafeTransferHistory(Bill? b, List<Account> allAccounts) {
    if (b == null || b.type != 2) return false;
    final originalSource = allAccounts
        .where((a) => a.id == b.accountId)
        .firstOrNull;
    final originalTarget = allAccounts
        .where((a) => a.id == b.toAccountId)
        .firstOrNull;
    return (originalSource == null ||
        originalTarget == null ||
        originalSource.id == originalTarget.id ||
        originalSource.type == 4 ||
        originalTarget.type == 4 ||
        originalSource.id == kAaCreditAccountId ||
        originalTarget.id == kAaCreditAccountId ||
        b.isAa ||
        b.aaGroupId != null ||
        b.settlementId != null ||
        Currency.tryFromCode(originalTarget.currency) == null ||
        b.currency != originalSource.currency ||
        b.amount != b.accountAmount ||
        b.amount < 0 ||
        (b.toAccountAmount != null &&
            (b.toAccountAmount! < 0 ||
                (originalSource.currency == originalTarget.currency
                    ? b.toAccountAmount != b.amount
                    : b.toAccountAmount == 0 || b.amount == 0))));
  }

  bool _needsReceived(Account source, Account target) =>
      source.currency != target.currency || _requireReceivedConfirmation;

  int? _incomingAmount(Account source, Account target, int units) =>
      _needsReceived(source, target)
      ? (_receivedConfirmed(source, target, units) ? _receivedAmount : null)
      : units;

  Future<void> _pickReceivedAmount(Account source, Account target) async {
    final units = evaluateMoneyExpression(_amount, _currency);
    if (_hasOperator || units == null || units <= 0 || source.id == target.id) {
      _snack('请先选择不同账户并输入有效出账金额，表达式需先按 =');
      return;
    }
    final signature = _transferSignature(source, target, units);
    final sameCurrency = source.currency == target.currency;
    final amount = await _showActualAmountDialog(
      context,
      currency: Currency.tryFromCode(target.currency)!,
      income: true,
      title: '转入账户实际入账',
      equalAmount: sameCurrency ? units : null,
      initial: _receivedConfirmed(source, target, units)
          ? _receivedAmount
          : sameCurrency
          ? units
          : null,
    );
    if (amount == null || !mounted || _type != 2) return;
    final current = _entryAccounts(
      ref.read(accountsProvider).value ?? const <Account>[],
    );
    final currentSource = current.where((a) => a.id == _accountId).firstOrNull;
    final currentTarget = current
        .where((a) => a.id == _toAccountId)
        .firstOrNull;
    final currentUnits = evaluateMoneyExpression(_amount, _currency);
    if (currentSource == null ||
        currentTarget == null ||
        currentUnits == null ||
        signature !=
            _transferSignature(currentSource, currentTarget, currentUnits)) {
      _snack('账户或出账金额已变化，请重新确认入账金额');
      return;
    }
    setState(() {
      _receivedAmount = amount;
      _receivedSignature = signature;
      _originalReceived = false;
      if (!sameCurrency) _requireReceivedConfirmation = true;
    });
  }

  String _signature(Account account, int units) =>
      '$_type|${_currency.code}|$units|${account.id}|${account.currency}';

  bool _actualConfirmed(Account account, int units) {
    final b = widget.bill;
    return _actualAmount != null &&
        (_actualSignature == _signature(account, units) ||
            (_originalActual &&
                b != null &&
                b.type == _type &&
                b.currency == _currency.code &&
                b.amount == units &&
                b.accountId == account.id));
  }

  bool get _useDefaultCategory =>
      widget.bill == null || widget.bill!.type != _type;

  String? _selectedCategory(List<Category> categories) => categorySelection(
    categories,
    _type,
    _categoryId,
    fallbackToRoot: _useDefaultCategory,
  );

  bool get _isSettlementEdit {
    final b = widget.bill;
    return b != null &&
        b.settlementId != null &&
        b.aaGroupId == null &&
        (b.type == 0 || b.type == 1);
  }

  @override
  void initState() {
    super.initState();
    final b = widget.bill;
    _type = b?.type ?? 0;
    _date = b == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(b.dateMs);
    _noteCtl = TextEditingController(text: b?.note ?? '');
    if (b != null) {
      _currency = Currency.tryFromCode(b.currency) ?? Currency.cny;
      _amount = formatMinorUnits(b.amount, _currency, grouping: false);
      _actualAmount = b.accountAmount;
      _originalActual = true;
      _categoryId = b.categoryId;
      _accountId = b.accountId;
      _toAccountId = b.toAccountId;
      _receivedAmount = b.toAccountAmount;
      _originalReceived = b.type == 2;
    }
  }

  @override
  void dispose() {
    _noteCtl.dispose();
    super.dispose();
  }

  // ---------- 金额输入与表达式 ----------

  String _segmentAfterOp() {
    final i = _amount.lastIndexOf(RegExp(r'[+-]'));
    return i < 0 ? _amount : _amount.substring(i + 1);
  }

  /// 表达式求值触发键「=」：结果替换表达式显示；非法输入提示「非法参数」
  bool get _hasOperator => _amount.contains('+') || _amount.contains('-');

  int _evaluatedCents() => evaluateMoneyExpression(_amount, _currency) ?? 0;

  void _evaluate() {
    if (_amount.isEmpty) return;
    final units = evaluateMoneyExpression(_amount, _currency);
    if (!_hasOperator || units == null || units < 0) {
      _snack('非法参数');
      return;
    }
    setState(() {
      _invalidateActual();
      _amount = formatMinorUnits(units, _currency, grouping: false);
    });
  }

  void _onKey(String k) {
    if (k == '=') {
      _evaluate();
      return;
    }
    setState(() {
      if (k == '+' || k == '-') {
        if (_amount.isEmpty) return;
        final last = _amount[_amount.length - 1];
        if (last == '+' || last == '-') {
          _invalidateActual();
          _amount = _amount.substring(0, _amount.length - 1) + k;
          return;
        }
        if (last == '.') _amount = _amount.substring(0, _amount.length - 1);
        if (_amount.isEmpty) return;
        if (_amount.length >= 256) return;
        _invalidateActual();
        _amount += k;
        return;
      }
      if (k == '.') {
        if (_currency.minorUnitDigits == 0 || _amount.length >= 256) return;
        final seg = _segmentAfterOp();
        if (seg.contains('.')) return;
        _invalidateActual();
        _amount += seg.isEmpty ? '0.' : '.';
        return;
      }
      if (_amount.length >= 256) return;
      final seg = _segmentAfterOp();
      final dot = seg.indexOf('.');
      if (dot >= 0 && seg.length - dot - 1 >= _currency.minorUnitDigits) return;
      _invalidateActual();
      if (seg == '0') {
        _amount = _amount.substring(0, _amount.length - 1) + k;
        return;
      }
      _amount += k;
    });
  }

  void _onBackspace() {
    if (_amount.isEmpty) return;
    setState(() {
      _invalidateActual();
      _amount = _amount.substring(0, _amount.length - 1);
    });
  }

  /// 只在按「=」后替换表达式，不自动换算用户输入。
  String get _displayAmount => _amount.isEmpty
      ? formatMinorUnits(0, _currency, grouping: false)
      : _amount;

  // ---------- 日期 ----------

  Future<void> _pickCurrency() async {
    final accounts = _entryAccounts(
      ref.read(accountsProvider).value ?? const <Account>[],
    );
    final originalAccountId = _effectiveAccountId(accounts);
    final picked = await showEntryCurrencyPicker(context, selected: _currency);
    if (picked == null || !mounted || picked == _currency) return;
    if (_aaRestricted && picked != Currency.cny) {
      _snack('AA 仅支持 CNY 交易和人民币账户');
      return;
    }
    if (originalAccountId == kAaCreditAccountId && picked != Currency.cny) {
      _snack('AA 挂账仅支持人民币，请先选择真实账户');
      return;
    }
    setState(() {
      _accountId = originalAccountId ?? _accountId;
      _currency = picked;
      _invalidateActual();
    });
  }

  Future<void> _pickActualAmount(Account account) async {
    final accountCurrency = Currency.tryFromCode(account.currency);
    final units = evaluateMoneyExpression(_amount, _currency);
    if (_hasOperator || units == null || units <= 0) {
      _snack('请先输入有效交易金额，表达式需先按 =');
      return;
    }
    if (accountCurrency == null) return;
    final signature = _signature(account, units);
    final amount = await _showActualAmountDialog(
      context,
      currency: accountCurrency,
      income: _type == 1,
      initial: _actualConfirmed(account, units) ? _actualAmount : null,
    );
    if (amount == null || !mounted || signature != _signature(account, units)) {
      return;
    }
    setState(() {
      _actualAmount = amount;
      _actualSignature = signature;
      _originalActual = false;
      // 固定用于确认的账户，Provider 重排不能把实扣应用到其他钱包。
      _accountId = account.id;
    });
  }

  String get _dateChipLabel {
    final now = DateTime.now();
    final sameDay =
        _date.year == now.year &&
        _date.month == now.month &&
        _date.day == now.day;
    final hm =
        '${_date.hour.toString().padLeft(2, '0')}:${_date.minute.toString().padLeft(2, '0')}';
    final day = sameDay ? '今天' : '${_date.month}月${_date.day}日';
    return '$day $hm';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked == null || !mounted) return;
    // 接着选时间，精确到分钟
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (!mounted) return;
    setState(() {
      _date = time == null
          ? DateTime(
              picked.year,
              picked.month,
              picked.day,
              _date.hour,
              _date.minute,
            )
          : DateTime(
              picked.year,
              picked.month,
              picked.day,
              time.hour,
              time.minute,
            );
    });
  }

  // ---------- 保存 / 删除 ----------

  Future<void> _save({bool again = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _saveDraft(again: again);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveDraft({bool again = false}) async {
    if (widget.bill?.settlementId != null) {
      return _saveSettlementLocalFields();
    }
    final db = ref.read(databaseProvider);
    final aaService = ref.read(aaSyncServiceProvider);
    final accounts = _entryAccounts(
      ref.read(accountsProvider).value ?? const <Account>[],
    );
    final categories = ref.read(categoriesProvider).value ?? const <Category>[];

    // 表达式必须按「=」求值后才是纯数字；带运算符或格式非法一律「非法参数」
    final raw = _amount.trim();
    if (raw.isEmpty) return _snack('请输入金额');
    final parsed = evaluateMoneyExpression(raw, _currency);
    if (_hasOperator || parsed == null) return _snack('非法参数');
    final cents = parsed;
    final accId = _effectiveAccountId(accounts) ?? '';
    final toId = transferTargetAccountId(accounts, _toAccountId, accId) ?? '';

    final catId = _selectedCategory(categories);

    if (cents <= 0) return _snack('请输入金额');
    if (accId.isEmpty) {
      return _snack(
        accounts.isEmpty || _accountId == null
            ? noEntryAccountMessage
            : staleEntryAccountMessage,
      );
    }
    final account = accounts.firstWhere((a) => a.id == accId);
    final crossCurrency = account.currency != _currency.code;
    if (_type != 2 && crossCurrency && !_actualConfirmed(account, cents)) {
      return _snack('请确认账户实际收付款额');
    }
    final actual = _type != 2 && crossCurrency ? _actualAmount! : cents;
    if (actual <= 0) return _snack('账户实际收付款额须大于零');
    // 转账只允许本人钱包互转：双方必填、互不相同、且不得涉及「AA挂账」
    // （跨人资金往来应记收入/支出，不允许以转账形式出现）
    Account? target;
    int? incoming;
    if (_type == 2) {
      if (accId.isEmpty || toId.isEmpty) {
        return _snack(
          _toAccountId == null ? '转账需至少两个不同的真实账户' : staleEntryAccountMessage,
        );
      }
      if (toId == accId) return _snack('转入账户需与转出账户不同');
      if (accId == kAaCreditAccountId || toId == kAaCreditAccountId) {
        return _snack('转账仅限本人钱包之间，跨人往来请记收入或支出');
      }
      target = accounts.firstWhere((a) => a.id == toId);
      if (account.currency != _currency.code) {
        return _snack('出账账户币种已变化，请重新选择账户');
      }
      incoming = _incomingAmount(account, target, cents);
      if (incoming == null || incoming <= 0) {
        return _snack('请确认转入账户实际入账金额');
      }
      if (account.currency == target.currency && incoming != cents) {
        return _snack('同币种转账的出账与入账金额必须一致');
      }
    }

    // 防重复入账：已存在相似账单（同类型 · 同金额 · 同一天）时需用户确认
    final similar = await db.findSimilarBills(
      type: _type,
      amount: cents,
      currency: _currency.code,
      dateMs: _date.millisecondsSinceEpoch,
      excludeId: widget.bill?.id,
    );
    if (similar.isNotEmpty && mounted) {
      final proceed = await _confirmDuplicate(similar);
      if (!proceed || !mounted) return;
    }

    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    final billId = widget.bill?.id ?? const Uuid().v4();
    var aaConverted = false;
    var ownerEdited = false;
    try {
      // 原始账单与共享组一起保存；遇到后台结算时不能留下部分改动。
      await db.transaction(() async {
        final original = widget.bill;
        final currentAccount = await db.getAccount(accId);
        if (currentAccount == null ||
            currentAccount.currency != account.currency ||
            (_type == 2 && currentAccount.type != account.type)) {
          throw StateError(staleEntryAccountMessage);
        }
        final selectedTarget = target;
        if (selectedTarget != null) {
          final currentTarget = await db.getAccount(selectedTarget.id);
          if (currentTarget == null ||
              currentTarget.currency != selectedTarget.currency ||
              currentTarget.type != selectedTarget.type) {
            throw StateError(staleEntryAccountMessage);
          }
        }
        if (original != null) {
          final current = await (db.select(
            db.bills,
          )..where((t) => t.id.equals(original.id))).getSingleOrNull();
          if (current == null || current.deletedAt != null) {
            throw StateError('账单已删除，请返回后重试');
          }
          if (current.categoryId != original.categoryId) {
            throw StateError('账单分类已转移，请返回重新打开');
          }
          if (await db.getAccount(current.accountId) == null) {
            throw StateError('原账户已不存在，无法确认历史币种，暂不能修改该账单');
          }
          if (current.type == 2 &&
              (current.toAccountId == null ||
                  await db.getAccount(current.toAccountId!) == null)) {
            throw StateError('原转入账户已不存在，暂不能修改该账单');
          }
          if (current != original) {
            throw StateError('账单已变化，请返回重新打开');
          }
        }
        await db.upsertBill(
          id: billId,
          type: _type,
          amount: cents,
          currency: _currency.code,
          accountAmount: actual,
          categoryId: _type == 2 ? null : catId,
          accountId: accId,
          toAccountId: _type == 2 ? toId : null,
          toAccountAmount: _type == 2 ? incoming : null,
          dateMs: _date.millisecondsSinceEpoch,
          note: _noteCtl.text.trim(),
          aaGroupId: widget.bill?.aaGroupId,
          settlementId: widget.bill?.settlementId,
          createdAt: widget.bill?.createdAt,
        );

        Category? selCat;
        for (final c in categories) {
          if (c.id == catId) {
            selCat = c;
            break;
          }
        }

        // 新建 AA 或普通账单转 AA；结算时才逐条生成收支。
        if (_aaOn && _type == 0 && widget.bill?.aaGroupId == null) {
          await aaService.createAaBillFor(
            billId: billId,
            totalAmount: cents,
            dateMs: _date.millisecondsSinceEpoch,
            note: _noteCtl.text.trim(),
            categoryName: selCat?.name ?? '其他',
            categoryEmoji: selCat?.emoji ?? '📦',
          );
          aaConverted = widget.bill != null;
        }

        final editGid = widget.bill?.aaGroupId;
        if (editGid != null && _type == 0) {
          final group = await db.getAaGroup(editGid);
          if (group == null) {
            throw StateError('AA 关联记录已变更，请返回后重试');
          }
          final myUid = await db.getMeta('myUid') ?? '';
          if (group.ownerUid == myUid) {
            await aaService.ownerUpdatedAaGroup(
              groupId: editGid,
              newTotal: cents,
              dateMs: _date.millisecondsSinceEpoch,
              note: _noteCtl.text.trim(),
              categoryName: selCat?.name ?? '其他',
              categoryEmoji: selCat?.emoji ?? '📦',
            );
            ownerEdited = true;
          }
        }
      });
    } on StateError catch (error) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _snack(error.message);
      }
      return;
    }

    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (ownerEdited) {
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('AA 账单已修改，请导出同步文件通知伙伴重新确认')),
      );
      return;
    }
    if (aaConverted) {
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('已转为 AA 平分账单，请导出同步文件通知伙伴')),
      );
      return;
    }
    if (again) {
      setState(() {
        _amount = '';
        _invalidateActual();
        _requireReceivedConfirmation = false;
        _noteCtl.clear();
      });
      _snack('已保存，继续记下一笔');
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _saveSettlementLocalFields() async {
    if (!_isSettlementEdit || _savingSettlement) return;
    final b = widget.bill!;
    final accounts = cnyEntryAccounts(
      ref.read(accountsProvider).value ?? const <Account>[],
      includeAaCredit: false,
    );
    if (accounts.isEmpty) return _snack(noCnyAccountMessage);
    if (!accounts.any((account) => account.id == (_accountId ?? b.accountId))) {
      return _snack(staleCnyAccountMessage);
    }
    setState(() => _savingSettlement = true);
    try {
      final db = ref.read(databaseProvider);
      final saved = await db.updateSettlementBillLocalFields(
        billId: b.id,
        settlementId: b.settlementId!,
        accountId: _accountId ?? b.accountId,
        note: _noteCtl.text.trim(),
      );
      // 系统返回后的退出动画中仍可能 mounted，不能再退掉下层详情。
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (!saved) {
        _snack('账单或账户已变更，请返回后重试');
        return;
      }
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _snack('保存失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _savingSettlement = false);
    }
  }

  Future<void> _delete() async {
    final b = widget.bill;
    if (b == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除账单'),
        content: const Text('确定删除这笔账单吗？（回收站功能将在后续版本提供）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await ref.read(databaseProvider).softDeleteBill(b.id);
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      } on StateError catch (error) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          _snack(error.message);
        }
      }
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 相似账单确认弹窗：列出已有的相似账单，用户确认后才入账
  Future<bool> _confirmDuplicate(List<Bill> similar) async {
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final categories = ref.read(categoriesProvider).value ?? const <Category>[];
    final accBy = {for (final a in accounts) a.id: a};
    final catBy = {for (final c in categories) c.id: c};
    String two(int v) => v.toString().padLeft(2, '0');

    final rows = <Widget>[];
    for (final b in similar.take(3)) {
      final d = DateTime.fromMillisecondsSinceEpoch(b.dateMs);
      final cat = b.categoryId == null ? null : catBy[b.categoryId];
      final acc = accBy[b.accountId];
      final label = b.type == 2
          ? '转账'
          : (cat?.name ?? (b.type == 1 ? '收入' : '支出'));
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            '${d.month}月${d.day}日 ${two(d.hour)}:${two(d.minute)} · '
            '$label · ${acc?.name ?? ''} · ${displayCurrencyAmount(BigInt.from(b.amount), b.currency)}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      );
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('可能重复记账'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已存在 ${similar.length} 笔相似账单（同币种 · 同类型 · 同金额 · 同一天）：'),
              const SizedBox(height: 8),
              ...rows,
              if (similar.length > 3)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '…等共 ${similar.length} 笔',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              const SizedBox(height: 8),
              const Text('仍要将这笔计入账单吗？'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('仍要保存'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---------- 图片识别记账 ----------

  Future<void> _pickOcrImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('拍照识别'),
              onTap: () => Navigator.pop(sctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(sctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
    );
    if (picked == null ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final navigator = Navigator.of(context);
    final editorRoute = ModalRoute.of(context);
    final loadingRoute = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Dialog(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: 16),
              Text('正在识别…'),
            ],
          ),
        ),
      ),
    );
    navigator.push(loadingRoute);
    bool closeLoading() {
      if (loadingRoute.navigator == null || !loadingRoute.isActive) {
        return false;
      }
      final wasCurrent = loadingRoute.isCurrent;
      navigator.removeRoute(loadingRoute);
      return wasCurrent;
    }

    final BillOcrResult result;
    try {
      result = await recognizeBill(picked.path);
    } catch (_) {
      if (mounted && closeLoading() && editorRoute?.isCurrent == true) {
        _snack('识别失败，请重试');
      }
      return;
    }
    if (!mounted || !closeLoading() || editorRoute?.isCurrent != true) return;
    await _showOcrSheet(result);
  }

  String? _guessAccountId(BillOcrResult r, List<Account> accounts) {
    String? byName(String text) {
      for (final a in accounts) {
        if (a.name.isNotEmpty && text.contains(a.name)) return a.id;
      }
      return null;
    }

    String? bank() {
      for (final a in accounts) {
        if (a.type == 1 || a.name.contains('银行')) return a.id;
      }
      return null;
    }

    // 1) 付款方式/支付方式标签行及其紧邻下一行（ML Kit 常把标签与值拆成两行）
    for (var i = 0; i < r.lines.length; i++) {
      final l = r.lines[i];
      if (RegExp('付款方式|支付方式|收款方式|扣款方式|付款账户').hasMatch(l)) {
        final next = i + 1 < r.lines.length ? r.lines[i + 1] : '';
        final t = '$l $next';
        final m = byName(t);
        if (m != null) return m;
        if (RegExp('储蓄卡|借记卡|信用卡|银行|招行|招商|工商|建设|农业|中行|交行').hasMatch(t)) {
          final b = bank();
          if (b != null) return b;
        }
        if (t.contains('微信') || t.contains('零钱')) {
          for (final a in accounts) {
            if (a.name.contains('微信')) return a.id;
          }
        }
        if (t.contains('支付宝') || t.contains('余额')) {
          for (final a in accounts) {
            if (a.name.contains('支付宝')) return a.id;
          }
        }
        if (t.contains('现金')) {
          for (final a in accounts) {
            if (a.name.contains('现金')) return a.id;
          }
        }
      }
    }
    // 2) 全行扫描：银行卡行（带卡号后缀或"储蓄卡"字样）
    for (final l in r.lines) {
      if (RegExp(r'储蓄卡|借记卡|信用卡').hasMatch(l) ||
          (RegExp(r'[（(]\d{3,5}[)）]').hasMatch(l) && l.contains('银行'))) {
        final m = byName(l) ?? bank();
        if (m != null) return m;
      }
    }
    // 3) 微信支付 / 支付宝余额 / 现金（排除"支付宝出行服务"这类商户行）
    for (final l in r.lines) {
      if (l.contains('微信支付') || l.contains('零钱')) {
        for (final a in accounts) {
          if (a.name.contains('微信')) return a.id;
        }
      }
      if (l.contains('支付宝') && !l.contains('服务') || l.contains('余额宝')) {
        for (final a in accounts) {
          if (a.name.contains('支付宝')) return a.id;
        }
      }
      if (l.contains('现金')) {
        for (final a in accounts) {
          if (a.name.contains('现金')) return a.id;
        }
      }
    }
    // 4) 商户名匹配（纸质小票场景）
    if (r.merchantGuess.isNotEmpty) {
      final m = byName(r.merchantGuess);
      if (m != null) return m;
    }
    return null;
  }

  String? _guessCategoryId(BillOcrResult r, List<Category> categories) {
    // 扫描全部识别文本（标签与值分行时关键信息可能在任意行）
    final text = '${r.merchantGuess} ${r.lines.join(' ')}';
    const table = <String, String>{
      '交通': '地铁|公交|打车|网约车|出租|出行|火车|高铁|机票|航空|加油|停车|充电|单车',
      '餐饮': '餐|外卖|美食|火锅|小吃|咖啡|奶茶|饭店|食堂|烧烤',
      '购物': '超市|购物|商城|百货|淘宝|京东|拼多多',
      '医疗': '医院|药店|药房|诊所|门诊',
      '通讯': '话费|流量|移动|联通|电信',
      '居住': '房租|物业|水电|燃气|宽带',
      '娱乐': '电影|游戏|KTV|娱乐|景区|门票',
      '教育': '教育|培训|学费|书店|图书',
      '宠物': '宠物|宠物店',
    };
    for (final e in table.entries) {
      if (RegExp(e.value, caseSensitive: false).hasMatch(text)) {
        for (final c in CategoryHierarchy(categories).rootsOfKind(_type)) {
          if (_type == 0 && c.name == e.key) return c.id;
        }
      }
    }
    return null;
  }

  Future<void> _showOcrSheet(BillOcrResult result) async {
    final accounts = _entryAccounts(
      ref.read(accountsProvider).value ?? const <Account>[],
    );
    final categories = ref.read(categoriesProvider).value ?? const <Category>[];
    final accMatch = _guessAccountId(result, accounts);
    final catMatch = _guessCategoryId(result, categories);
    final first = result.amounts.isEmpty ? null : result.amounts.first;
    final adopted = await showModalBottomSheet<OcrAdoptResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => OcrEntrySheet(
        candidates: result.amounts,
        initialAmount: first?.amountText ?? '',
        initialCurrency: first?.currency,
        cnyOnly: _type == 2 || _aaRestricted,
        initialNote: result.noteSuggestion ?? result.merchantGuess,
        initialDate: result.detectedDateMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(result.detectedDateMs!),
        initialAccountId: accMatch ?? _effectiveAccountId(accounts),
        initialCategoryId: catMatch == null
            ? _selectedCategory(categories)
            : categorySelection(categories, _type, catMatch),
        accounts: accounts,
        categories: categories,
        kind: _type,
        previewLines: result.lines,
      ),
    );
    if (adopted == null || !mounted) return;
    if ((_type == 2 || _aaRestricted) && adopted.currency != Currency.cny) {
      _snack('AA 与当前转账入口仅支持人民币');
      return;
    }
    final units = parseMoneyToMinorUnits(adopted.amountText, adopted.currency);
    if (units == null || units <= 0) {
      _snack('金额无效，请手动输入后保存');
      return;
    }
    setState(() {
      _invalidateActual();
      _currency = adopted.currency;
      _amount = formatMinorUnits(units, _currency, grouping: false);
      _noteCtl.text = adopted.noteText;
      if (adopted.date != null) _date = adopted.date!;
      if (adopted.accountId != null) _accountId = adopted.accountId;
      if (adopted.categoryId != null) _categoryId = adopted.categoryId;
    });
    _snack('已填入识别结果，请核对后保存');
  }

  // ---------- 账户选择 ----------

  Future<void> _pickAccount({bool to = false}) async {
    final accounts = _entryAccounts(
      ref.read(accountsProvider).value ?? const <Account>[],
    );
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sctx) => SafeArea(
        child: ConstrainedBox(
          // 账户多时不能顶破屏幕：限高 + 内部滚动（修复 bottom overflowed）
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sctx).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  to ? '选择转入账户' : '选择账户',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    if (accounts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _type == 2 || _isSettlementEdit
                              ? noCnyAccountMessage
                              : noEntryAccountMessage,
                        ),
                      ),
                    for (final a in accounts)
                      ListTile(
                        leading: Text(
                          a.emoji,
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(a.name),
                        subtitle: Text(a.currency),
                        onTap: () => Navigator.pop(sctx, a.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (to) {
        if (_toAccountId != picked) _invalidateActual();
        _toAccountId = picked;
      } else {
        if (_accountId != picked) _invalidateActual();
        _accountId = picked;
      }
    });
  }

  // ---------- 构建 ----------

  Widget _settlementEditor(List<Account> accounts, List<Category> categories) {
    final b = widget.bill!;
    Account? account;
    for (final a in accounts) {
      if (a.id == (_accountId ?? b.accountId)) account = a;
    }
    Category? category;
    for (final c in categories) {
      if (c.id == b.categoryId) category = c;
    }
    final d = DateTime.fromMillisecondsSinceEpoch(b.dateMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return Scaffold(
      appBar: AppBar(
        title: const Text('修改结算账单'),
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: _savingSettlement
              ? null
              : () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('仅修改本机账户和备注，不影响双方结算。'),
            const SizedBox(height: 20),
            Text(
              '${b.type == 0 ? '支出' : '收入'} ¥ ${centsToText(b.amount)}',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: b.type == 0 ? kExpenseColor : kIncomeColor,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '分类：${category == null ? '—' : '${category.emoji} ${CategoryHierarchy(categories).pathOf(category.id)}'}',
            ),
            const SizedBox(height: 8),
            Text(
              '时间：${d.year}-${two(d.month)}-${two(d.day)} '
              '${two(d.hour)}:${two(d.minute)}',
            ),
            const SizedBox(height: 16),
            const Text('账户'),
            Align(
              alignment: Alignment.centerLeft,
              child: _accountChip(
                account?.name ?? '请选择真实账户',
                account?.emoji,
                () {
                  if (!_savingSettlement) _pickAccount();
                },
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtl,
              enabled: !_savingSettlement,
              decoration: const InputDecoration(labelText: '备注'),
              minLines: 1,
              maxLines: 4,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _savingSettlement ? null : () => _save(),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allAccounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final accounts = _entryAccounts(allAccounts);
    final categories =
        ref.watch(categoriesProvider).value ?? const <Category>[];
    final meta = ref.watch(metaProvider).value ?? const <String, String>{};
    final paired = meta.containsKey('pairSecret');
    final myUid = meta['myUid'] ?? '';
    final isTransfer = _type == 2;

    final b = widget.bill;
    final hasForeignAccount =
        b != null &&
        allAccounts.any(
          (a) =>
              (a.id == b.accountId || a.id == b.toAccountId) &&
              a.currency != 'CNY',
        );
    // 旧人民币关联转账沿用既有只读页面，不将它当作普通本人转账开放。
    if (b != null &&
        b.type == 2 &&
        b.currency == 'CNY' &&
        !hasForeignAccount &&
        (b.isAa || b.aaGroupId != null || b.settlementId != null)) {
      return _AaLockedView(
        bill: b,
        accounts: allAccounts,
        categories: categories,
      );
    }
    if (b != null &&
        (_unsafeTransferHistory(b, allAccounts) ||
            Currency.tryFromCode(b.currency) == null ||
            allAccounts.any(
              (a) =>
                  a.id == b.accountId &&
                  Currency.tryFromCode(a.currency) == null,
            ) ||
            ((b.settlementId != null || b.aaGroupId != null) &&
                (b.currency != 'CNY' || hasForeignAccount)))) {
      return Scaffold(
        appBar: AppBar(title: const Text('暂不能编辑')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Text('该历史账单的币种或关联尚不能安全编辑，现有金额和账户将保留。'),
        ),
      );
    }
    if (_isSettlementEdit) {
      return _settlementEditor(accounts, categories);
    }
    AaGroup? aaGroup;
    if (b?.aaGroupId != null) {
      final groups = ref.watch(aaGroupsProvider);
      for (final g in groups.value ?? const <AaGroup>[]) {
        if (g.id == b!.aaGroupId) aaGroup = g;
      }
      if (aaGroup == null || aaGroup.settled) {
        return _AaLockedView(
          bill: b!,
          accounts: accounts,
          categories: categories,
          message: aaGroup?.settled == true
              ? '该 AA 账单已结算，为保持结算一致，不能再修改或删除。'
              : '正在读取 AA 关联记录；如无法加载，请返回后重试。',
        );
      }
    }
    // 旧结算转账、AA 伴生应收及异常混合关联保持只读。
    final lockedAa =
        b != null &&
        ((b.aaGroupId != null && b.type == 1) || b.settlementId != null);
    if (lockedAa) {
      return _AaLockedView(bill: b, accounts: accounts, categories: categories);
    }

    final isAaOwnerEdit =
        aaGroup != null &&
        b != null &&
        aaGroup.ownerUid == myUid &&
        b.type == 0;
    final isAaShareEdit =
        aaGroup != null &&
        b != null &&
        aaGroup.ownerUid != myUid &&
        b.type == 0;

    final effAccountId = _effectiveAccountId(accounts);
    // 首次展示后固定默认钱包；列表刷新/重排不能替用户换账户。
    if (_accountId == null && effAccountId != null) _accountId = effAccountId;
    final effToId = transferTargetAccountId(
      accounts,
      _toAccountId,
      effAccountId,
    );
    if (isTransfer && _toAccountId == null && effToId != null) {
      _toAccountId = effToId;
    }
    final effCatId = _selectedCategory(categories);

    Account? selAcc;
    for (final a in accounts) {
      if (a.id == effAccountId) selAcc = a;
    }
    Account? selToAcc;
    for (final a in accounts) {
      if (a.id == effToId) selToAcc = a;
    }
    if (isTransfer && selAcc != null) {
      final sourceCurrency = Currency.tryFromCode(selAcc.currency)!;
      if (_currency != sourceCurrency) {
        _invalidateActual();
        _currency = sourceCurrency;
      }
      final originalTarget = allAccounts
          .where((a) => a.id == b?.toAccountId)
          .firstOrNull;
      if (b?.type == 2 &&
          originalTarget != null &&
          originalTarget.currency != b!.currency) {
        _requireReceivedConfirmation = true;
      }
    }
    final centsNow = _evaluatedCents();

    final amountColor = _type == 0
        ? kExpenseColor
        : (_type == 1 ? kIncomeColor : Colors.black87);

    // 底部提示行
    final hints = <String>[];
    if (isTransfer) {
      if (selAcc != null && selToAcc != null && centsNow > 0) {
        hints.add(
          '出账 ${_currency.code} ${formatMinorUnits(centsNow, _currency, grouping: false)} → 入账 ${selToAcc.currency} ${_incomingAmount(selAcc, selToAcc, centsNow) == null ? '待确认' : formatMinorUnits(_incomingAmount(selAcc, selToAcc, centsNow)!, Currency.tryFromCode(selToAcc.currency)!, grouping: false)}',
        );
      }
    } else {
      if (_aaOn && _type == 0 && centsNow > 0) {
        // 奇数总额多出的 1 分归垫付方（我）承担：伙伴份额向下取整
        final partnerShare = AaSyncService.shareOfNonPayer(centsNow);
        hints.add(
          'AA平分：我 ¥${centsToText(centsNow - partnerShare)} / 伙伴 ¥${centsToText(partnerShare)}',
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [_typeTab(0, '支出'), _typeTab(1, '收入'), _typeTab(2, '转账')],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: '图片识别记账',
            onPressed: _saving
                ? null
                : isTransfer
                ? () => _snack('转账请手动确认出账和入账金额，图片识别仅用于收支记账')
                : _pickOcrImage,
          ),
          if (widget.bill != null &&
              widget.bill!.aaGroupId == null &&
              widget.bill!.settlementId == null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: SafeArea(
          child: Column(
            children: [
              if (isAaOwnerEdit || isAaShareEdit)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kPrimaryColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.sync, size: 16, color: kPrimaryColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          isAaOwnerEdit
                              ? 'AA 账单 · 保存后请导出同步文件，伙伴将重新确认'
                              : 'AA 份额账单 · 金额与日期由伙伴账单决定，可修改账户/分类/备注（仅本机）',
                          style: const TextStyle(
                            fontSize: 12,
                            color: kPrimaryColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: isTransfer
                    ? _transferSummary(selAcc, selToAcc, centsNow)
                    : CategoryPicker(
                        key: ValueKey('category-picker-$_type'),
                        categories: categories,
                        kind: _type,
                        selectedId: effCatId,
                        fallbackToRoot: _useDefaultCategory,
                        onSelected: (id) => setState(() => _categoryId = id),
                        onManage: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const CategoriesPage(),
                          ),
                        ),
                      ),
              ),
              Container(
                color: Colors.grey.shade100,
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 备注 | 大金额
                    LayoutBuilder(
                      builder: (context, constraints) => Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _noteCtl,
                              enableInteractiveSelection: true,
                              maxLines: 1,
                              textInputAction: TextInputAction.done,
                              style: const TextStyle(fontSize: 14),
                              decoration: const InputDecoration(
                                hintText: '点此输入备注…',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth * 0.72,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      _displayAmount,
                                      key: const ValueKey(
                                        'entry-displayed-amount',
                                      ),
                                      style: TextStyle(
                                        fontSize: 32,
                                        fontWeight: FontWeight.bold,
                                        color: amountColor,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                if (isTransfer)
                                  Tooltip(
                                    message: '币种由出账账户决定',
                                    child: Text(
                                      ' ${_currency.code}',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  )
                                else
                                  Tooltip(
                                    message: '选择币种',
                                    child: TextButton(
                                      key: const ValueKey('entry-currency'),
                                      style: TextButton.styleFrom(
                                        minimumSize: const Size(48, 48),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                        ),
                                      ),
                                      onPressed: _pickCurrency,
                                      child: Semantics(
                                        label:
                                            '${_currency.displayName} ${_currency.code}，选择币种',
                                        excludeSemantics: true,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              _currency.code,
                                              style: const TextStyle(
                                                fontSize: 13,
                                              ),
                                            ),
                                            const Icon(
                                              Icons.arrow_drop_down,
                                              size: 16,
                                            ),
                                          ],
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
                    if (hints.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.only(top: 2, bottom: 4),
                        child: Text(
                          hints.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    // 属性胶囊行
                    SizedBox(
                      height: 44,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            if (isTransfer) ...[
                              _accountChip(
                                '出 · ${selAcc?.name ?? '选择'}',
                                selAcc?.emoji,
                                () => _pickAccount(),
                                key: const ValueKey('entry-account'),
                              ),
                              _accountChip(
                                '入 · ${selToAcc?.name ?? '选择'}',
                                selToAcc?.emoji,
                                () => _pickAccount(to: true),
                                key: const ValueKey('transfer-to-account'),
                              ),
                            ] else ...[
                              _accountChip(
                                selAcc?.name ?? '选择账户',
                                selAcc?.emoji,
                                () => _pickAccount(),
                                key: const ValueKey('entry-account'),
                              ),
                              if (selAcc != null &&
                                  selAcc.currency != _currency.code)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ActionChip(
                                    key: const ValueKey('entry-account-amount'),
                                    label: Text(
                                      '${_type == 1 ? '实收' : '实扣'} ${selAcc.currency} ${_actualConfirmed(selAcc, centsNow) ? formatMinorUnits(_actualAmount!, Currency.tryFromCode(selAcc.currency)!, grouping: false) : '待确认'}',
                                    ),
                                    onPressed: () => _pickActualAmount(selAcc!),
                                  ),
                                ),
                              // AA 开关：仅新建账单或普通账单（可后补转换）显示；已是 AA 账单的编辑态隐藏
                              if (paired &&
                                  _type == 0 &&
                                  widget.bill?.aaGroupId == null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: FilterChip(
                                    label: const Text('🤝 AA平分'),
                                    selected: _aaOn,
                                    onSelected: (v) {
                                      if (v &&
                                          (_currency != Currency.cny ||
                                              selAcc?.currency != 'CNY')) {
                                        _snack('AA 仅支持 CNY 交易和人民币账户');
                                        return;
                                      }
                                      setState(() => _aaOn = v);
                                    },
                                  ),
                                ),
                            ],
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ActionChip(
                                key: const ValueKey('entry-date'),
                                label: Text(_dateChipLabel),
                                onPressed: isAaShareEdit ? null : _pickDate,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (isAaShareEdit)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: kPrimaryColor,
                            ),
                            onPressed: () => _save(),
                            child: const Text('保存'),
                          ),
                        ),
                      )
                    else
                      NumberPad(
                        onKey: _onKey,
                        onBackspace: _onBackspace,
                        onClear: () => setState(() {
                          _invalidateActual();
                          _amount = '';
                        }),
                        onSave: () => _save(),
                        onSaveAndAgain: widget.bill == null
                            ? () => _save(again: true)
                            : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _accountChip(
    String label,
    String? emoji,
    VoidCallback onTap, {
    Key? key,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        key: key,
        label: Text(
          '${emoji ?? '💳'} $label',
          style: const TextStyle(fontSize: 13),
        ),
        onPressed: onTap,
      ),
    );
  }

  Widget _transferSummary(Account? source, Account? target, int units) {
    final incoming = source != null && target != null
        ? _incomingAmount(source, target, units)
        : null;
    final targetCurrency = target == null
        ? null
        : Currency.tryFromCode(target.currency);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '出账 · ${source?.name ?? '请选择账户'} · ${source?.currency ?? '—'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          '${_currency.code} $_displayAmount',
          style: const TextStyle(fontSize: 24),
        ),
        const SizedBox(height: 16),
        Text(
          '入账 · ${target?.name ?? '请选择账户'} · ${target?.currency ?? '—'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          key: const ValueKey('transfer-received-amount'),
          onPressed:
              source == null ||
                  target == null ||
                  !_needsReceived(source, target)
              ? null
              : () => _pickReceivedAmount(source, target),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '入账 ${target?.currency ?? '—'} ${incoming == null || targetCurrency == null ? '待确认' : formatMinorUnits(incoming, targetCurrency, grouping: false)}',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          source?.currency == target?.currency
              ? '同币种出入金额相等；手续费请单独记支出。'
              : '分别确认两侧实际金额，不自动换算汇率。',
        ),
      ],
    );
  }

  Widget _typeTab(int t, String label) {
    final selected = _type == t;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // AA 账单编辑时锁定类型（支出），防止破坏与伙伴的关联结构
      onTap: () {
        if (widget.bill?.aaGroupId != null) {
          _snack('AA 账单类型不可变更');
          return;
        }
        if (_type == t || _saving) return;
        setState(() {
          _invalidateActual();
          _type = t;
          if (t != 0) _aaOn = false;
          _categoryId = null;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 3,
              color: selected ? kPrimaryColor : Colors.transparent,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 17,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected ? Colors.black87 : Colors.grey,
          ),
        ),
      ),
    );
  }
}

/// AA 账单的只读详情（M2 文件版锁定编辑，保证双方账本一致）
class _AaLockedView extends StatelessWidget {
  const _AaLockedView({
    required this.bill,
    required this.accounts,
    required this.categories,
    this.message = 'AA 账单与伙伴账本关联，为保持双方一致暂不支持编辑或删除。',
  });

  final Bill bill;
  final List<Account> accounts;
  final List<Category> categories;
  final String message;

  @override
  Widget build(BuildContext context) {
    Category? cat;
    for (final c in categories) {
      if (c.id == bill.categoryId) cat = c;
    }
    Account? acc;
    for (final a in accounts) {
      if (a.id == bill.accountId) acc = a;
    }
    final d = DateTime.fromMillisecondsSinceEpoch(bill.dateMs);
    final nature = bill.type == 0
        ? 'AA 支出 / 份额'
        : (bill.type == 1 ? 'AA 挂账应收' : 'AA 结算转账');

    return Scaffold(
      appBar: AppBar(title: const Text('AA 账单')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${cat?.emoji ?? '🤝'} ${CategoryHierarchy(categories).pathOf(bill.categoryId)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '¥ ${centsToText(bill.amount)}',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: bill.type == 0
                          ? kExpenseColor
                          : (bill.type == 1 ? kIncomeColor : Colors.black87),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _kv('性质', nature),
                  _kv('账户', acc?.name ?? 'AA挂账'),
                  _kv('日期', '${d.year}-${d.month}-${d.day}'),
                  if (bill.note.isNotEmpty) _kv('备注', bill.note),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              k,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

Future<int?> _showActualAmountDialog(
  BuildContext context, {
  required Currency currency,
  required bool income,
  int? initial,
  String? title,
  int? equalAmount,
}) => showDialog<int>(
  context: context,
  builder: (_) => _ActualAmountDialog(
    currency: currency,
    income: income,
    initial: initial,
    title: title,
    equalAmount: equalAmount,
  ),
);

class _ActualAmountDialog extends StatefulWidget {
  const _ActualAmountDialog({
    required this.currency,
    required this.income,
    this.initial,
    this.title,
    this.equalAmount,
  });

  final Currency currency;
  final bool income;
  final int? initial;
  final String? title;
  final int? equalAmount;

  @override
  State<_ActualAmountDialog> createState() => _ActualAmountDialogState();
}

class _ActualAmountDialogState extends State<_ActualAmountDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial == null
        ? ''
        : formatMinorUnits(widget.initial!, widget.currency, grouping: false),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final units = parseMoneyToMinorUnits(_controller.text, widget.currency);
    if (units == null || units <= 0) {
      setState(
        () => _error = widget.currency.minorUnitDigits == 0
            ? '请输入大于零的整数金额'
            : '请输入大于零且不超过两位小数的金额',
      );
      return;
    }
    if (widget.equalAmount != null && units != widget.equalAmount) {
      setState(() => _error = '同币种转账的出账与入账金额必须一致');
      return;
    }
    Navigator.pop(context, units);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title ?? (widget.income ? '账户实际入账' : '账户实际扣款')),
    content: TextField(
      key: const ValueKey('account-amount-input'),
      controller: _controller,
      autofocus: true,
      maxLength: 256,
      keyboardType: TextInputType.numberWithOptions(
        decimal: widget.currency.minorUnitDigits > 0,
      ),
      decoration: InputDecoration(
        labelText: widget.currency.code,
        helperText: '填写账户实际收付款额，不自动换算',
        errorText: _error,
      ),
      onSubmitted: (_) => _confirm(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _confirm, child: const Text('确认')),
    ],
  );
}
