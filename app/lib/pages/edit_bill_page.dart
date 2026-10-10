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
import '../utils/money.dart';
import '../widgets/category_picker.dart';
import '../widgets/number_pad.dart';
import 'categories_page.dart';

/// 记账 / 编辑账单页（钱迹风格布局）：
/// 顶部类型页签 + 5列分类宫格 + 底部（备注 | 大金额 CNY / 属性胶囊 / 计算键盘）
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
      _amount = centsToPlain(b.amount);
      _categoryId = b.categoryId;
      _accountId = b.accountId;
      _toAccountId = b.toAccountId;
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

  /// 表达式合法性：数字(＋/−数字)*，每段数字格式合法（拒绝空段/多余小数点等）
  bool _validExpr(String t) {
    if (t.isEmpty) return false;
    for (final seg in t.split(RegExp(r'[+-]'))) {
      if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(seg)) return false;
    }
    return true;
  }

  /// 去掉末尾多余小数点（用户输入「45.」不视为非法）
  String _normalizeExpr(String t) =>
      t.endsWith('.') ? t.substring(0, t.length - 1) : t;

  /// 当前输入的求值金额（分）：表达式合法时取求值结果，否则 0
  int _evaluatedCents() {
    final t = _normalizeExpr(_amount.trim());
    if (!_validExpr(t)) return 0;
    final v = _evalExpr();
    return v == null ? 0 : parseMoneyToCents(v.toStringAsFixed(2));
  }

  /// 按「=」：表达式求值并把结果显示为纯数字；未按 = 直接保存会报「非法参数」
  void _evaluate() {
    final t = _normalizeExpr(_amount.trim());
    if (t.isEmpty) return;
    if (!_validExpr(t) || !_hasOperator) {
      _snack('非法参数');
      return;
    }
    final v = _evalExpr();
    if (v == null || v < 0) {
      _snack('非法参数');
      return;
    }
    setState(() => _amount = centsToPlain(parseMoneyToCents(v.toStringAsFixed(2))));
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
          _amount = _amount.substring(0, _amount.length - 1) + k;
          return;
        }
        if (last == '.') _amount = _amount.substring(0, _amount.length - 1);
        if (_amount.isEmpty) return;
        _amount += k;
        return;
      }
      if (k == '.') {
        final seg = _segmentAfterOp();
        if (seg.contains('.')) return;
        _amount += seg.isEmpty ? '0.' : '.';
        return;
      }
      if (_amount.length >= 20) return;
      final seg = _segmentAfterOp();
      final dot = seg.indexOf('.');
      if (dot >= 0 && seg.length - dot - 1 >= 2) return;
      if (seg == '0') {
        _amount = _amount.substring(0, _amount.length - 1) + k;
        return;
      }
      _amount += k;
    });
  }

  void _onBackspace() {
    if (_amount.isEmpty) return;
    setState(() => _amount = _amount.substring(0, _amount.length - 1));
  }

  double? _evalExpr() {
    final t = _amount.trim();
    if (t.isEmpty) return null;
    var sum = 0.0;
    var sign = 1.0;
    var numBuf = '';
    for (final ch in t.split('')) {
      if (ch == '+' || ch == '-') {
        sum += sign * (double.tryParse(numBuf) ?? 0);
        sign = ch == '-' ? -1.0 : 1.0;
        numBuf = '';
      } else {
        numBuf += ch;
      }
    }
    final last = double.tryParse(numBuf);
    if (last == null) return numBuf.isEmpty ? sum : null;
    return sum + sign * last;
  }

  /// 显示所键入的内容（表达式原样显示，按「=」后才变成求值结果）
  String get _displayAmount => _amount.isEmpty ? '0.00' : _amount;

  // ---------- 日期 ----------

  String get _dateChipLabel {
    final now = DateTime.now();
    final sameDay = _date.year == now.year &&
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
      lastDate: DateTime(2100),
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
          ? DateTime(picked.year, picked.month, picked.day, _date.hour,
              _date.minute)
          : DateTime(picked.year, picked.month, picked.day, time.hour,
              time.minute);
    });
  }

  // ---------- 保存 / 删除 ----------

  Future<void> _save({bool again = false}) async {
    if (widget.bill?.settlementId != null) {
      return _saveSettlementLocalFields();
    }
    final db = ref.read(databaseProvider);
    final aaService = ref.read(aaSyncServiceProvider);
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final categories =
        ref.read(categoriesProvider).value ?? const <Category>[];

    // 表达式必须按「=」求值后才是纯数字；带运算符或格式非法一律「非法参数」
    final raw = _normalizeExpr(_amount.trim());
    if (raw.isEmpty) return _snack('请输入金额');
    if (_hasOperator || !_validExpr(raw)) return _snack('非法参数');
    final cents = parseMoneyToCents(raw);
    final accId = _accountId ?? (accounts.isNotEmpty ? accounts.first.id : '');
    final toId = _toAccountId ?? (accounts.length > 1 ? accounts[1].id : '');

    final catId = categorySelection(categories, _type, _categoryId);

    if (cents <= 0) return _snack('请输入金额');
    if (accId.isEmpty) return _snack('请先在「我的 → 账户与资产」中创建账户');
    // 转账只允许本人钱包互转：双方必填、互不相同、且不得涉及「AA挂账」
    // （跨人资金往来应记收入/支出，不允许以转账形式出现）
    if (_type == 2) {
      if (accId.isEmpty || toId.isEmpty) {
        return _snack('转账必须同时选择转出与转入账户');
      }
      if (toId == accId) return _snack('转入账户需与转出账户不同');
      if (accId == kAaCreditAccountId || toId == kAaCreditAccountId) {
        return _snack('转账仅限本人钱包之间，跨人往来请记收入或支出');
      }
    }

    // 防重复入账：已存在相似账单（同类型 · 同金额 · 同一天）时需用户确认
    final similar = await db.findSimilarBills(
      type: _type,
      amount: cents,
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
        await db.upsertBill(
          id: billId,
          type: _type,
          amount: cents,
          categoryId: _type == 2 ? null : catId,
          accountId: accId,
          toAccountId: _type == 2 ? toId : null,
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
      messenger.showSnackBar(const SnackBar(
          content: Text('AA 账单已修改，请导出同步文件通知伙伴重新确认')));
      return;
    }
    if (aaConverted) {
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(const SnackBar(
          content: Text('已转为 AA 平分账单，请导出同步文件通知伙伴')));
      return;
    }
    if (again) {
      setState(() {
        _amount = '';
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
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
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
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// 相似账单确认弹窗：列出已有的相似账单，用户确认后才入账
  Future<bool> _confirmDuplicate(List<Bill> similar) async {
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final categories =
        ref.read(categoriesProvider).value ?? const <Category>[];
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
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          '${d.month}月${d.day}日 ${two(d.hour)}:${two(d.minute)} · '
          '$label · ${acc?.name ?? ''} · ¥${centsToText(b.amount)}',
          style: const TextStyle(fontSize: 13),
        ),
      ));
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
              Text('已存在 ${similar.length} 笔相似账单（同类型 · 同金额 · 同一天）：'),
              const SizedBox(height: 8),
              ...rows,
              if (similar.length > 3)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('…等共 ${similar.length} 笔',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              const SizedBox(height: 8),
              const Text('仍要将这笔计入账单吗？'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('仍要保存')),
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
    final picked =
        await ImagePicker().pickImage(source: source, maxWidth: 1600);
    if (picked == null || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Dialog(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            SizedBox(width: 16),
            Text('正在识别…'),
          ]),
        ),
      ),
    );
    final BillOcrResult result;
    try {
      result = await recognizeBill(picked.path);
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _snack('识别失败：$e');
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
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
        if (RegExp('储蓄卡|借记卡|信用卡|银行|招行|招商|工商|建设|农业|中行|交行')
            .hasMatch(t)) {
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
      if (l.contains('支付宝') && !l.contains('服务') ||
          l.contains('余额宝')) {
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
    final accounts = ref.read(accountsProvider).value ?? const <Account>[];
    final categories =
        ref.read(categoriesProvider).value ?? const <Category>[];
    final accMatch = _guessAccountId(result, accounts);
    final catMatch = _guessCategoryId(result, categories);
    debugPrint('[OCR] source=${result.source} '
        'merchant=${result.merchantGuess} '
        'accMatch=$accMatch catMatch=$catMatch');

    final adopted = await showModalBottomSheet<_OcrAdoptResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OcrSheet(
        candidates: result.amounts,
        initialAmount: result.amounts.isEmpty
            ? ''
            : result.amounts.first.toStringAsFixed(2),
        initialNote: result.noteSuggestion ?? result.merchantGuess,
        initialDate: result.detectedDateMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(result.detectedDateMs!),
        initialAccountId: accMatch ?? _accountId,
        initialCategoryId:
            categorySelection(categories, _type, catMatch ?? _categoryId),
        accounts: accounts,
        categories: categories,
        kind: _type,
        previewLines: result.lines,
      ),
    );

    if (adopted == null || !mounted) return;
    final cents = parseMoneyToCents(adopted.amountText);
    if (cents <= 0) {
      _snack('金额无效，请手动输入后保存');
      return;
    }
    setState(() {
      _amount = centsToPlain(cents);
      _noteCtl.text = adopted.noteText;
      if (adopted.date != null) _date = adopted.date!;
      if (adopted.accountId != null) _accountId = adopted.accountId;
      if (adopted.categoryId != null) _categoryId = adopted.categoryId;
    });
    _snack('已填入识别结果，请核对后保存');
  }

  // ---------- 账户选择 ----------

  Future<void> _pickAccount({bool to = false}) async {
    var accounts = ref.read(accountsProvider).value ?? const <Account>[];
    // 转账和结算收支只允许真实钱包，排除「AA挂账」虚拟账户。
    if (_type == 2 || _isSettlementEdit) {
      accounts = accounts.where((a) => a.id != kAaCreditAccountId).toList();
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sctx) => SafeArea(
        child: ConstrainedBox(
          // 账户多时不能顶破屏幕：限高 + 内部滚动（修复 bottom overflowed）
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sctx).size.height * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(to ? '选择转入账户' : '选择账户',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final a in accounts)
                      ListTile(
                        leading: Text(a.emoji,
                            style: const TextStyle(fontSize: 22)),
                        title: Text(a.name),
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
    if (picked == null) return;
    setState(() {
      if (to) {
        _toAccountId = picked;
      } else {
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
          onPressed: _savingSettlement ? null : () => Navigator.of(context).pop(),
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
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final categories =
        ref.watch(categoriesProvider).value ?? const <Category>[];
    final meta = ref.watch(metaProvider).value ?? const <String, String>{};
    final paired = meta.containsKey('pairSecret');
    final myUid = meta['myUid'] ?? '';
    final isTransfer = _type == 2;

    final b = widget.bill;
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
          bill: b!, accounts: accounts, categories: categories,
          message: aaGroup?.settled == true
              ? '该 AA 账单已结算，为保持结算一致，不能再修改或删除。'
              : '正在读取 AA 关联记录；如无法加载，请返回后重试。',
        );
      }
    }
    // 旧结算转账、AA 伴生应收及异常混合关联保持只读。
    final lockedAa = b != null &&
        ((b.aaGroupId != null && b.type == 1) || b.settlementId != null);
    if (lockedAa) {
      return _AaLockedView(
          bill: b, accounts: accounts, categories: categories);
    }

    final isAaOwnerEdit =
        aaGroup != null && b != null && aaGroup.ownerUid == myUid && b.type == 0;
    final isAaShareEdit = aaGroup != null &&
        b != null &&
        aaGroup.ownerUid != myUid &&
        b.type == 0;

    final effAccountId =
        _accountId ?? (accounts.isNotEmpty ? accounts.first.id : null);
    final effToId = _toAccountId ?? (accounts.length > 1 ? accounts[1].id : null);
    final effCatId = categorySelection(categories, _type, _categoryId);

    Account? selAcc;
    for (final a in accounts) {
      if (a.id == effAccountId) selAcc = a;
    }
    Account? selToAcc;
    for (final a in accounts) {
      if (a.id == effToId) selToAcc = a;
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
            '「${selAcc.name}」→「${selToAcc.name}」¥ ${centsToText(centsNow)}');
      }
    } else {
      if (_aaOn && _type == 0 && centsNow > 0) {
        // 奇数总额多出的 1 分归垫付方（我）承担：伙伴份额向下取整
        final partnerShare = AaSyncService.shareOfNonPayer(centsNow);
        hints.add(
            'AA平分：我 ¥${centsToText(centsNow - partnerShare)} / 伙伴 ¥${centsToText(partnerShare)}');
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
          children: [
            _typeTab(0, '支出'),
            _typeTab(1, '收入'),
            _typeTab(2, '转账'),
          ],
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.photo_camera_outlined),
              tooltip: '图片识别记账',
              onPressed: _pickOcrImage),
          if (widget.bill != null &&
              widget.bill!.aaGroupId == null &&
              widget.bill!.settlementId == null)
            IconButton(
                icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: SafeArea(
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
                            fontSize: 12, color: kPrimaryColor),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: isTransfer
                  ? const SizedBox.shrink()
                  : CategoryPicker(
                      key: ValueKey('category-picker-$_type'),
                      categories: categories,
                      kind: _type,
                      selectedId: effCatId,
                      onSelected: (id) => setState(() => _categoryId = id),
                      onManage: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const CategoriesPage()),
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
                  Row(
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
                      Text(
                        _displayAmount,
                        style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: amountColor),
                      ),
                      const SizedBox(width: 4),
                      const Text(' CNY',
                          style:
                              TextStyle(fontSize: 13, color: Colors.grey)),
                    ],
                  ),
                  if (hints.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.only(top: 2, bottom: 4),
                      child: Text(
                        hints.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
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
                                () => _pickAccount()),
                            _accountChip(
                                '入 · ${selToAcc?.name ?? '选择'}',
                                selToAcc?.emoji,
                                () => _pickAccount(to: true)),
                          ] else ...[
                            _accountChip(
                                selAcc?.name ?? '选择账户',
                                selAcc?.emoji,
                                () => _pickAccount()),
                            // AA 开关：仅新建账单或普通账单（可后补转换）显示；已是 AA 账单的编辑态隐藏
    if (paired && _type == 0 && widget.bill?.aaGroupId == null)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: FilterChip(
                                  label: const Text('🤝 AA平分'),
                                  selected: _aaOn,
                                  onSelected: (v) =>
                                      setState(() => _aaOn = v),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ActionChip(
                                label: Text(_dateChipLabel),
                                onPressed:
                                    isAaShareEdit ? null : _pickDate,
                              ),
                            ),
                          ],
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
                              backgroundColor: kPrimaryColor),
                          onPressed: () => _save(),
                          child: const Text('保存'),
                        ),
                      ),
                    )
                  else
                    NumberPad(
                      onKey: _onKey,
                      onBackspace: _onBackspace,
                      onClear: () => setState(() => _amount = ''),
                      onSave: () => _save(),
                      onSaveAndAgain:
                          widget.bill == null ? () => _save(again: true) : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _accountChip(String label, String? emoji, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        label: Text('${emoji ?? '💳'} $label',
            style: const TextStyle(fontSize: 13)),
        onPressed: onTap,
      ),
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
        if (_type == t) return;
        setState(() {
          _type = t;
          _categoryId = null;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                width: 3,
                color: selected ? kPrimaryColor : Colors.transparent),
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
                  Text('${cat?.emoji ?? '🤝'} ${CategoryHierarchy(categories).pathOf(bill.categoryId)}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(
                    '¥ ${centsToText(bill.amount)}',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: bill.type == 0
                          ? kExpenseColor
                          : (bill.type == 1
                              ? kIncomeColor
                              : Colors.black87),
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
              child: Text(k,
                  style:
                      const TextStyle(fontSize: 13, color: Colors.grey))),
          Expanded(
              child:
                  Text(v, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// 采用识别结果时带回的数据
class _OcrAdoptResult {
  const _OcrAdoptResult({
    required this.amountText,
    required this.noteText,
    this.date,
    this.accountId,
    this.categoryId,
  });

  final String amountText;
  final String noteText;
  final DateTime? date;
  final String? accountId;
  final String? categoryId;
}

/// 识别结果面板（五要素全部可修改）：控制器由本 State 持有，随路由关闭正确释放
class _OcrSheet extends StatefulWidget {
  const _OcrSheet({
    required this.candidates,
    required this.initialAmount,
    required this.initialNote,
    this.initialDate,
    this.initialAccountId,
    this.initialCategoryId,
    required this.accounts,
    required this.categories,
    required this.kind,
    required this.previewLines,
  });

  final List<double> candidates;
  final String initialAmount;
  final String initialNote;
  final DateTime? initialDate;
  final String? initialAccountId;
  final String? initialCategoryId;
  final List<Account> accounts;
  final List<Category> categories;
  final int kind;
  final List<String> previewLines;

  @override
  State<_OcrSheet> createState() => _OcrSheetState();
}

class _OcrSheetState extends State<_OcrSheet> {
  late final TextEditingController _amountCtl =
      TextEditingController(text: widget.initialAmount);
  late final TextEditingController _noteCtl =
      TextEditingController(text: widget.initialNote);
  DateTime? _selDate;
  String? _selAccId;
  String? _selCatId;

  @override
  void initState() {
    super.initState();
    _selDate = widget.initialDate;
    _selAccId = widget.initialAccountId;
    _selCatId = widget.initialCategoryId;
  }

  @override
  void dispose() {
    _amountCtl.dispose();
    _noteCtl.dispose();
    super.dispose();
  }

  Account? get _accObj {
    for (final a in widget.accounts) {
      if (a.id == _selAccId) return a;
    }
    return null;
  }

  Category? get _catObj {
    for (final c in widget.categories) {
      if (c.id == _selCatId) return c;
    }
    return null;
  }

  String _fmtDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _adopt(BuildContext sctx) {
    Navigator.pop(
      sctx,
      _OcrAdoptResult(
        amountText: _amountCtl.text.trim(),
        noteText: _noteCtl.text.trim(),
        date: _selDate,
        accountId: _selAccId,
        categoryId: _selCatId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acc = _accObj;
    final cat = _catObj;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('图片识别结果',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            // 金额：可直接输入，候选一键填入
            Row(
              children: [
                const Text('¥ ',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: kExpenseColor)),
                Expanded(
                  child: TextField(
                    controller: _amountCtl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: '输入金额',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            if (widget.candidates.length > 1)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final a in widget.candidates.take(8))
                    ActionChip(
                      label: Text(a.toStringAsFixed(2)),
                      onPressed: () =>
                          setState(() => _amountCtl.text = a.toStringAsFixed(2)),
                    ),
                ],
              ),
            const Divider(height: 20),
            // 日期：点选修改（日期 + 时间，精确到分钟）
            _row(
              Icons.schedule,
              '日期',
              _selDate == null ? '使用当前时间' : _fmtDate(_selDate!),
              () async {
                final base = _selDate ?? DateTime.now();
                final picked = await showDatePicker(
                    context: context,
                    initialDate: base,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100));
                if (picked == null || !mounted || !context.mounted) return;
                final time = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.fromDateTime(base),
                );
                if (!mounted) return;
                setState(() => _selDate = time == null
                    ? DateTime(picked.year, picked.month, picked.day,
                        base.hour, base.minute)
                    : DateTime(picked.year, picked.month, picked.day,
                        time.hour, time.minute));
              },
            ),
            // 备注：可编辑
            TextField(
              controller: _noteCtl,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                hintText: '备注（在哪里消费？）',
                prefixIcon: Icon(Icons.edit_note, size: 20),
                isDense: true,
              ),
            ),
            // 账户：点选更换
            _row(
              Icons.account_balance_wallet,
              '账户',
              acc == null ? '保持当前选择' : '${acc.emoji} ${acc.name}',
              () async {
                final id = await showModalBottomSheet<String>(
                  context: context,
                  builder: (bctx) => SafeArea(
                    child: ConstrainedBox(
                      // 限高 + 内部滚动，避免账户多时 bottom overflowed
                      constraints: BoxConstraints(
                          maxHeight:
                              MediaQuery.of(bctx).size.height * 0.6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Padding(
                              padding: EdgeInsets.all(12),
                              child: Text('选择账户',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600))),
                          Flexible(
                            child: ListView(
                              shrinkWrap: true,
                              padding: EdgeInsets.zero,
                              children: [
                                for (final a in widget.accounts)
                                  ListTile(
                                    leading: Text(a.emoji,
                                        style:
                                            const TextStyle(fontSize: 22)),
                                    title: Text(a.name),
                                    onTap: () => Navigator.pop(bctx, a.id),
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
                if (id != null) setState(() => _selAccId = id);
              },
            ),
            // 分类：点选更换
            _row(
              Icons.category,
              '分类',
              cat == null ? '未选择' : '${cat.emoji} ${CategoryHierarchy(widget.categories).pathOf(cat.id)}',
              () async {
                final id = await showCategoryPicker(
                  context: context,
                  categories: widget.categories,
                  kind: widget.kind,
                  selectedId: _selCatId,
                );
                if (id != null && mounted) setState(() => _selCatId = id);
              },
            ),
            const Divider(height: 20),
            const Text('识别文本预览：',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                  for (final l in widget.previewLines.take(12))
                    Text(l,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black45)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: kPrimaryColor),
                onPressed: () => _adopt(context),
                child: const Text('采用并填入'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String label, String value, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Colors.grey),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
