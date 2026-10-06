import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../data/app_database.dart';
import '../data/presets.dart';
import '../providers.dart';
import '../sync/aa_sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'edit_bill_page.dart';

/// AA 共享页：配对 / 差额与结算 / 加密文件同步 / 待确认 / AA 账单列表
class AaPage extends ConsumerWidget {
  const AaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metaProvider).value ?? const <String, String>{};
    final paired = meta.containsKey('pairSecret');

    return Scaffold(
      appBar: AppBar(title: const Text('AA 共享')),
      body: paired ? _Dashboard(meta: meta) : const _PairingForm(),
    );
  }

  // 省得每个子组件重复写：这里仅作为静态入口，实际逻辑在下方各组件中
  static void showSnack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// ---------------- 配对表单 ----------------

class _PairingForm extends ConsumerStatefulWidget {
  const _PairingForm();

  @override
  ConsumerState<_PairingForm> createState() => _PairingFormState();
}

class _PairingFormState extends ConsumerState<_PairingForm> {
  final _myName = TextEditingController();
  final _partnerName = TextEditingController();
  final _secret = TextEditingController();
  final _secret2 = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _myName.dispose();
    _partnerName.dispose();
    _secret.dispose();
    _secret2.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final myName = _myName.text.trim();
    final partnerName = _partnerName.text.trim();
    final s1 = _secret.text;
    final s2 = _secret2.text;
    if (myName.isEmpty || partnerName.isEmpty) {
      return AaPage.showSnack(context, '请填写双方昵称');
    }
    if (s1.length < 6) return AaPage.showSnack(context, '配对口令至少 6 位');
    if (s1 != s2) return AaPage.showSnack(context, '两次口令不一致');

    await ref.read(aaSyncServiceProvider).setupPairing(
          myName: myName,
          partnerName: partnerName,
          secret: s1,
        );
    if (mounted) {
      AaPage.showSnack(context, '配对完成，已创建「AA挂账」账户');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: const [
                  Text('🤝', style: TextStyle(fontSize: 26)),
                  SizedBox(width: 8),
                  Text('建立配对',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 10),
                const Text(
                  '无服务器模式：与伙伴约定同一个「配对口令」，AA 数据以加密文件互传'
                  '（微信/QQ发送 .aas 文件）。口令用于端到端加密，只有你们二人能解开，'
                  '请务必牢记。双方在本机各自填写一次即可完成配对。',
                  style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _myName,
          decoration: const InputDecoration(
              labelText: '我的昵称', prefixIcon: Icon(Icons.person_outline)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _partnerName,
          decoration: const InputDecoration(
              labelText: '伙伴昵称', prefixIcon: Icon(Icons.favorite_outline)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _secret,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: '配对口令（至少 6 位，双方相同）',
            prefixIcon: const Icon(Icons.password),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _secret2,
          obscureText: _obscure,
          decoration: const InputDecoration(
              labelText: '确认口令', prefixIcon: Icon(Icons.password)),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
              backgroundColor: kPrimaryColor,
              padding: const EdgeInsets.symmetric(vertical: 14)),
          child: const Text('建立配对'),
        ),
      ],
    );
  }
}

// ---------------- 已配对仪表盘 ----------------

/// 我的份额（分）：垫付方=总额-伙伴份额；接收方=伙伴份额
int _myShare(AaGroup g, String myUid) {
  final partnerShare = AaSyncService.shareOfNonPayer(g.totalAmount);
  return g.payerUid == myUid ? g.totalAmount - partnerShare : partnerShare;
}

/// AA 状态文案（设计图枚举：应收/应付 → 分区承载；拒绝/待修改/删除 → 行内状态）
/// AA 状态枚举（图 1）：应收 / 拒绝 / 待修改
/// status2：应收方(发起方)看「待修改」，应付方(接收方)看「拒绝」
/// status3：已转普通收支，不在 AA 列表显示
String _statusText(AaGroup g, String myUid) {
  if (g.settled) return '已结算';
  switch (g.status) {
    case 2:
      return g.ownerUid == myUid ? '待修改' : '拒绝';
    case 3:
      return '已转普通收支';
    default:
      return '应收';
  }
}

String _fmtDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.month}-${d.day.toString().padLeft(2, '0')}';
}

/// AA 账单分区（应收/应付/已同步）：默认折叠到 8 条，过长时按钮展开
class _GroupsSection extends StatefulWidget {
  const _GroupsSection({
    required this.title,
    required this.groups,
    required this.myUid,
    required this.accent,
  });

  final String title;
  final List<AaGroup> groups;
  final String myUid;
  final Color accent;

  @override
  State<_GroupsSection> createState() => _GroupsSectionState();
}

class _GroupsSectionState extends State<_GroupsSection> {
  static const _collapseTo = 8;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.groups;
    if (g.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
        child: Text('${widget.title}：暂无',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    final shown = _expanded || g.length <= _collapseTo
        ? g
        : g.sublist(0, _collapseTo);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
          child: Text('${widget.title}（${g.length}）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: widget.accent)),
        ),
        for (final item in shown)
        for (final item in shown)
          ListTile(
            dense: true,
            leading:
                Text(item.categoryEmoji, style: const TextStyle(fontSize: 20)),
            title: Text(
              'AA平分：${item.categoryName}${item.note.isEmpty ? '' : ' · ${item.note}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Row(
              children: [
                Expanded(
                  child: Text(_statusText(item, widget.myUid),
                      style: const TextStyle(fontSize: 12)),
                ),
                Text('¥ ${centsToText(_myShare(item, widget.myUid))}',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: item.payerUid == widget.myUid
                            ? kPrimaryColor
                            : kExpenseColor)),
              ],
            ),
          ),
        if (g.length > _collapseTo)
          Align(
            alignment: Alignment.center,
            child: TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded
                  ? '收起'
                  : '展开全部 ${g.length} 条（账单较多，已折叠）'),
            ),
          ),
      ],
    );
  }
}

class _Dashboard extends ConsumerStatefulWidget {
  const _Dashboard({required this.meta});

  final Map<String, String> meta;

  @override
  ConsumerState<_Dashboard> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<_Dashboard> {
  /// 批量确认模式（长按待入账行进入）
  bool _batchMode = false;
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final myUid = widget.meta['myUid'] ?? '';
    final partnerName = widget.meta['partnerName'] ?? '伙伴';
    final groups = ref.watch(aaGroupsProvider).value ?? const <AaGroup>[];
    final settlements =
        ref.watch(settlementsProvider).value ?? const <Settlement>[];
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];

    final linkedIds =
        ref.watch(linkedAaGroupIdsProvider).value ?? const <String>{};
    var net = 0;
    var unsettled = 0;
    for (final g in groups) {
      if (!AaSyncService.countsTowardBalance(g)) continue;
      unsettled++;
      final share = AaSyncService.shareOfNonPayer(g.totalAmount);
      net += g.payerUid == myUid ? share : -share;
    }
    final pendingMine = groups
        .where((g) =>
            g.ownerUid != myUid &&
            g.status == 0 &&
            !g.settled &&
            !linkedIds.contains(g.id))
        .toList();
    // 退出批量模式时清空选择；没有待入账项时自动退出
    if (pendingMine.isEmpty && _batchMode) {
      _batchMode = false;
      _selected.clear();
    }
    // 发起方待处理：被伙伴退回的 AA 账单（挂起不计差额，等发起方决定，§4.3）
    final returnedMine = groups
        .where((g) => g.ownerUid == myUid && g.status == 2 && !g.settled)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
      children: [
        _balanceCard(context, ref, net, unsettled, partnerName, accounts),
        const SizedBox(height: 12),
        _syncCard(context, ref, partnerName),
        if (pendingMine.isNotEmpty) ...[
          const SizedBox(height: 12),
          _pendingCard(context, ref, pendingMine),
        ],
        if (returnedMine.isNotEmpty) ...[
          const SizedBox(height: 12),
          _returnedCard(context, ref, returnedMine),
        ],
        const SizedBox(height: 12),
        _groupsCard([for (final g in groups) if (g.status != 3) g], myUid),
        if (settlements.isNotEmpty) ...[
          const SizedBox(height: 12),
          _settlementsCard(settlements, myUid),
        ],
        const SizedBox(height: 12),
        _dangerCard(context, ref),
      ],
    );
  }

  // ---- 差额卡片 ----

  Widget _balanceCard(BuildContext context, WidgetRef ref, int net,
      int unsettled, String partnerName, List<Account> accounts) {
    final iReceive = net > 0;
    final color =
        net == 0 ? kPrimaryColor : (iReceive ? kPrimaryColor : kExpenseColor);
    final title = net == 0
        ? '已两清 🤝'
        : (iReceive ? '$partnerName 应转给你' : '你应转给 $partnerName');
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
            colors: [color, color.withValues(alpha: 0.78)]),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 13, color: Colors.white70)),
          const SizedBox(height: 6),
          Text(
            net == 0 ? '—' : '¥ ${centsToText(net.abs())}',
            style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text('基于 $unsettled 笔未结算 AA 账单',
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
          if (net != 0)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white24,
                  foregroundColor: Colors.white,
                ),
                onPressed: () =>
                    _settleDialog(context, ref, net, accounts, partnerName),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: const Text('去结算'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _settleDialog(BuildContext context, WidgetRef ref, int net,
      List<Account> accounts, String partnerName) async {
    final realAccounts =
        accounts.where((a) => a.id != kAaCreditAccountId).toList();
    if (realAccounts.isEmpty) {
      AaPage.showSnack(context, '请先在「账本」中创建真实账户');
      return;
    }
    var selected = realAccounts.first.id;
    final noteCtl = TextEditingController();
    final iReceive = net > 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDState) => AlertDialog(
          title: const Text('AA 结算'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                iReceive
                    ? '$partnerName 转给你 ¥ ${centsToText(net)}'
                    : '你转给 $partnerName ¥ ${centsToText(net.abs())}',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text('确认后将核销全部未结算 AA 账单（退回挂起/已取消的除外），'
                  '并按应付/应收明细逐条生成收支账单。'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: InputDecoration(
                    labelText: iReceive ? '收入到账户' : '付款账户'),
                items: [
                  for (final a in realAccounts)
                    DropdownMenuItem(
                        value: a.id, child: Text('${a.emoji} ${a.name}')),
                ],
                onChanged: (v) {
                  if (v != null) setDState(() => selected = v);
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteCtl,
                decoration:
                    const InputDecoration(labelText: '备注（可选）'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, true),
                child: const Text('确认结算')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await ref
            .read(aaSyncServiceProvider)
            .settle(accountId: selected, note: noteCtl.text.trim());
        if (context.mounted) {
          AaPage.showSnack(context, '已结算。记得「导出并发送」同步文件通知伙伴');
        }
      } catch (e) {
        if (context.mounted) AaPage.showSnack(context, '结算失败：$e');
      }
    }
  }

  // ---- 同步卡片 ----

  Widget _syncCard(BuildContext context, WidgetRef ref, String partnerName) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.sync_outlined, size: 18, color: kPrimaryColor),
              const SizedBox(width: 6),
              const Text('同步 · 加密文件互传',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: Text('上次导出：${widget.meta['lastExportAt'] ?? '—'}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey))),
              Expanded(
                  child: Text('上次导入：${widget.meta['lastImportAt'] ?? '—'}',
                      textAlign: TextAlign.end,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: kPrimaryColor),
                  onPressed: () => _export(context, ref),
                  icon: const Icon(Icons.upload_outlined, size: 18),
                  label: const Text('导出并发送'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _import(context, ref),
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('导入伙伴文件'),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              '导出后把 .aas 文件通过微信/QQ 发给 $partnerName，对方在本页导入。'
              '仅同步 AA 数据，普通账单永不外传。',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    String path;
    try {
      path = await ref.read(aaSyncServiceProvider).exportSyncFile();
    } catch (e) {
      if (context.mounted) AaPage.showSnack(context, '导出失败：$e');
      return;
    }
    if (!context.mounted) return;
    final fileName =
        path.split(Platform.pathSeparator).last; // e.g. aasync_1005_1710.aas

    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
                padding: EdgeInsets.all(12),
                child: Text('导出同步文件',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('系统分享（微信/QQ 发送）'),
              subtitle: const Text('手机上推荐，直接发给伙伴'),
              onTap: () => Navigator.pop(sctx, 'share'),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('保存到指定位置'),
              subtitle: const Text('存到「下载」等公共目录，模拟器或无微信时用'),
              onTap: () => Navigator.pop(sctx, 'save'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;

    if (choice == 'save') {
      try {
        final saved = await FilePicker.saveFile(
          fileName: fileName,
          bytes: await File(path).readAsBytes(),
          dialogTitle: '保存同步文件',
        );
        if (context.mounted) {
          AaPage.showSnack(
              context, saved == null ? '已取消保存' : '已保存：$saved');
        }
      } catch (e) {
        if (context.mounted) AaPage.showSnack(context, '保存失败：$e');
      }
      return;
    }

    await SharePlus.instance.share(ShareParams(
      files: [XFile(path)],
      text: 'AA记账同步文件，请在 AA 页导入',
    ));
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    try {
      final f = await FilePicker.pickFile();
      final path = f?.path;
      if (path == null) return;
      final msg =
          await ref.read(aaSyncServiceProvider).importSyncFile(path);
      if (context.mounted) AaPage.showSnack(context, msg);
      // 导入后如有待入账的伙伴账单，依次弹出选账户/分类/备注
      if (context.mounted) await _openPendingSheets(context, ref);
    } catch (e) {
      debugPrint('[AASync] import error: $e');
      if (context.mounted) {
        AaPage.showSnack(context, '导入失败：$e');
      }
    }
  }

  // ---- 待入账（伙伴的 AA 账单；点行逐笔选账户/分类/备注，长按进批量模式） ----

  Widget _pendingCard(
      BuildContext context, WidgetRef ref, List<AaGroup> pending) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(_batchMode ? '批量确认（已选 ${_selected.length}/${pending.length}）' : '待你入账（${pending.length}）',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (_batchMode)
                TextButton(
                  onPressed: () => setState(() {
                    _batchMode = false;
                    _selected.clear();
                  }),
                  child: const Text('退出批量'),
                ),
            ]),
            if (!_batchMode)
              const Text('点行逐笔入账（可选账户/分类/备注）；长按任意一行进入批量确认',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            for (final g in pending)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    if (_batchMode)
                      Checkbox(
                        value: _selected.contains(g.id),
                        onChanged: (v) => setState(() =>
                            v == true ? _selected.add(g.id) : _selected.remove(g.id)),
                      ),
                    Text(g.categoryEmoji, style: const TextStyle(fontSize: 20)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          if (_batchMode) {
                            setState(() => _selected.contains(g.id)
                                ? _selected.remove(g.id)
                                : _selected.add(g.id));
                          } else {
                            _openSheet(context, ref, g);
                          }
                        },
                        onLongPress: () => setState(() {
                          _batchMode = true;
                          _selected.add(g.id);
                        }),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${g.categoryName}${g.note.isEmpty ? '' : ' · ${g.note}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 14,
                                  decoration: _batchMode
                                      ? TextDecoration.none
                                      : TextDecoration.underline,
                                  color: kPrimaryColor),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '总额 ¥ ${centsToText(g.totalAmount)} · 我的份额 ¥ ${centsToText(AaSyncService.shareOfNonPayer(g.totalAmount))}',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!_batchMode)
                      TextButton(
                        style: TextButton.styleFrom(
                            foregroundColor: kExpenseColor),
                        onPressed: () async {
                          final reason = await askReturnReason(context);
                          if (reason == null) return; // 取消
                          await ref
                              .read(aaSyncServiceProvider)
                              .setGroupStatus(g.id, 2, reason: reason);
                          if (context.mounted) {
                            AaPage.showSnack(context, '已退回，等待伙伴处理');
                          }
                        },
                        child: const Text('退回'),
                      ),
                  ],
                ),
              ),
            if (_batchMode)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 6),
                child: Row(children: [
                  TextButton(
                    onPressed: () => setState(
                        () => _selected.length == pending.length
                            ? _selected.clear()
                            : _selected.addAll(pending.map((g) => g.id))),
                    child: Text(_selected.length == pending.length
                        ? '取消全选'
                        : '全选'),
                  ),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: kPrimaryColor),
                      onPressed: _selected.isEmpty
                          ? null
                          : () async {
                              final picked = pending
                                  .where((g) => _selected.contains(g.id))
                                  .toList();
                              final categories = ref.read(categoriesProvider)
                                      .value ??
                                  const <Category>[];
                              await ref
                                  .read(aaSyncServiceProvider)
                                  .adoptShareBillsDefault(picked, categories);
                              if (!mounted || !context.mounted) return;
                              setState(() {
                                _batchMode = false;
                                _selected.clear();
                              });
                              AaPage.showSnack(
                                  context, '已按默认模板批量入账 ${picked.length} 笔');
                            },
                      child: const Text('批量入账（默认模板）'),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: kExpenseColor),
                    onPressed: _selected.isEmpty
                        ? null
                        : () async {
                            final service =
                                ref.read(aaSyncServiceProvider);
                            for (final g in pending) {
                              if (_selected.contains(g.id)) {
                                await service.setGroupStatus(g.id, 2);
                              }
                            }
                            if (!mounted || !context.mounted) return;
                            setState(() {
                              _batchMode = false;
                              _selected.clear();
                            });
                            AaPage.showSnack(context, '已批量退回');
                          },
                    child: const Text('批量退回'),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  // ---- 待处理（伙伴退回的 AA 账单，发起方决定后续，§4.3） ----

  Widget _returnedCard(
      BuildContext context, WidgetRef ref, List<AaGroup> returned) {
    final myUid = widget.meta['myUid'] ?? '';
    final bills = ref.watch(allBillsProvider).value ?? const <Bill>[];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('待你处理（${returned.length}）',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const Text('伙伴已退回，暂不计入差额。可改金额重发（需再确认）或转普通收支。',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            for (final g in returned)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(g.categoryEmoji,
                          style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${g.categoryName}${g.note.isEmpty ? '' : ' · ${g.note}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_fmtDate(g.dateMs)} · 总额 ¥ ${centsToText(g.totalAmount)} · 我的份额 ¥ ${centsToText(_myShare(g, myUid))}',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey),
                            ),
                            if ((g.statusNote ?? '').isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text('退回理由：${g.statusNote}',
                                  style: const TextStyle(
                                      fontSize: 12, color: kExpenseColor)),
                            ],
                          ],
                        ),
                      ),
                    ]),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: const Text('改金额重发'),
                          onPressed: () => _reissue(context, ref, g, bills),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.link_off, size: 16),
                          label: const Text('取消 AA'),
                          onPressed: () => _cancelAa(context, ref, g),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                              foregroundColor: kExpenseColor),
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: const Text('转普通收支'),
                          onPressed: () => _cancelAa(context, ref, g),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 改金额重发（§4.3 ①）：打开垫付方全额账单的编辑页，保存后状态回「待伙伴确认」
  void _reissue(
      BuildContext context, WidgetRef ref, AaGroup g, List<Bill> bills) {
    Bill? full;
    for (final b in bills) {
      if (b.aaGroupId == g.id && b.type == 0 && b.amount == g.totalAmount) {
        full = b;
        break;
      }
    }
    if (full == null) {
      AaPage.showSnack(context, '未找到对应的垫付账单，无法重发');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EditBillPage(bill: full)),
    );
  }

  /// 删除AA属性 → 转普通收支记录（图 1 需求）：垫付账单转普通账单，分摊组置「已转普通收支」同步给伙伴
  Future<void> _cancelAa(BuildContext context, WidgetRef ref, AaGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('转普通收支'),
        content: const Text('删除 AA 属性后，垫付账单将转为普通收支记录（不再是 AA），伙伴的份额账单同步作废。确定转换吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('转普通收支')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(aaSyncServiceProvider).cancelAaGroup(groupId: g.id);
    if (context.mounted) {
      AaPage.showSnack(context, '已转普通收支，请导出同步文件通知伙伴');
    }
  }

  Future<String?> _openSheet(
      BuildContext context, WidgetRef ref, AaGroup g) {
    if (!context.mounted) return Future.value();
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AaShareSheet(
        group: g,
        service: ref.read(aaSyncServiceProvider),
      ),
    );
  }

  /// 依次处理所有待入账的伙伴账单（用户中断即停，剩余留在 AA 页）
  Future<void> _openPendingSheets(BuildContext context, WidgetRef ref) async {
    final pending =
        await ref.read(aaSyncServiceProvider).pendingShareGroups();
    if (pending.isEmpty || !context.mounted) return;
    final res = await _openSheet(context, ref, pending.first);
    if (res == null || !context.mounted) return;
    await _openPendingSheets(context, ref);
  }

  // ---- AA 账单列表 ----

  /// AA 账单三分区（设计图）：应收（我垫付未结算）/ 应付（伙伴垫付未结算）/ 已同步（完成）。
  /// 每区默认折叠到 8 条，账单过多时按需展开。
  Widget _groupsCard(List<AaGroup> groups, String myUid) {
    final active = [
      for (final g in groups)
        if (!g.settled && g.status != 3) g
    ];
    final receivable = [
      for (final g in active)
        if (g.payerUid == myUid) g
    ];
    final payable = [
      for (final g in active)
        if (g.payerUid != myUid) g
    ];
    final synced = [for (final g in groups) if (g.settled) g];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
              child: Text('AA 账单',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            _GroupsSection(
                title: '应收账单（我垫付 · 未结算）',
                groups: receivable,
                myUid: myUid,
                accent: kPrimaryColor),
            _GroupsSection(
                title: '应付账单（伙伴垫付 · 未结算）',
                groups: payable,
                myUid: myUid,
                accent: kExpenseColor),
            _GroupsSection(
                title: '已同步（完成）',
                groups: synced,
                myUid: myUid,
                accent: Colors.black54),
          ],
        ),
      ),
    );
  }

  // ---- 结算记录 ----
  Widget _settlementsCard(List<Settlement> settlements, String myUid) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
              child: Text('结算记录（${settlements.length}）',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            for (final s in settlements)
              ListTile(
                dense: true,
                leading: Icon(
                  s.receiverUid == myUid
                      ? Icons.south_west
                      : Icons.north_east,
                  color: s.receiverUid == myUid ? kIncomeColor : kExpenseColor,
                  size: 20,
                ),
                title: Text(
                    s.receiverUid == myUid ? 'AA结算 · 收款' : 'AA结算 · 付款',
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                    '${_fmtDate(s.dateMs)}${s.note.isEmpty ? '' : ' · ${s.note}'}',
                    style: const TextStyle(fontSize: 12)),
                trailing: Text(
                  '${s.receiverUid == myUid ? '+' : '-'}${centsToText(s.amount)}',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: s.receiverUid == myUid
                          ? kIncomeColor
                          : kExpenseColor),
                ),
                // 点开查看该笔结算覆盖的逐条明细（图 2 右）
                onTap: () => _settlementDetail(context, ref, s),
              ),
          ],
        ),
      ),
    );
  }

  /// 结算明细（图 2 右）：「AA平分：结算」+ 逐条 项目/金额
  Future<void> _settlementDetail(
      BuildContext context, WidgetRef ref, Settlement s) async {
    final groups = await ref
        .read(databaseProvider)
        .groupsOfSettlement(s.id);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('AA平分：结算'),
        content: SizedBox(
          width: double.maxFinite,
          child: groups.isEmpty
              ? const Text('该笔结算没有明细记录',
                  style: TextStyle(fontSize: 13, color: Colors.grey))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final g in groups)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${g.categoryName}${g.note.isEmpty ? '' : ' · ${g.note}'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            Text(
                              '¥ ${centsToText(AaSyncService.shareOfNonPayer(g.totalAmount))}',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  // ---- 危险操作 ----

  Widget _dangerCard(BuildContext context, WidgetRef ref) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.link_off, color: kExpenseColor),
        title: const Text('解除配对'),
        subtitle: const Text('清除本机配对信息（AA 账单数据保留只读）'),
        onTap: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('解除配对'),
              content: const Text('解除后将无法继续同步新的 AA 账单，'
                  '历史 AA 账单与结算记录保留。确定解除吗？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('解除')),
              ],
            ),
          );
          if (ok == true) {
            await ref.read(aaSyncServiceProvider).resetPairing();
            if (context.mounted) {
              AaPage.showSnack(context, '已解除配对');
            }
          }
        },
      ),
    );
  }
}

/// 退回 AA 账单前询问理由（可留空）：返回 null=取消，'' 或文本=确认退回
Future<String?> askReturnReason(BuildContext context) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: const Text('退回 AA 账单'),
      content: TextField(
        controller: ctl,
        maxLength: 40,
        decoration: const InputDecoration(
          labelText: '退回理由（可选）',
          hintText: '例如：这笔应该按 60/40 分',
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(dctx, ctl.text.trim()),
            child: const Text('退回')),
      ],
    ),
  );
}

/// AA 份额入账面板（图 2 流程）：只展示明细并确认入账——不选账户/分类、
/// 不在明细生成任何信息；付款账户在「去结算」时选择，结算完成后按应付
/// 明细逐条生成支出账单。返回值：'adopt' 已入账并确认 / 'return' 已退回 / null 取消
class AaShareSheet extends StatelessWidget {
  const AaShareSheet({
    super.key,
    required this.group,
    required this.service,
  });

  final AaGroup group;
  final AaSyncService service;

  Future<void> _confirm(BuildContext context) async {
    await service.confirmShare(group: group);
    if (context.mounted) Navigator.pop(context, 'adopt');
  }

  Future<void> _returnBill(BuildContext context) async {
    final reason = await askReturnReason(context);
    if (reason == null) return; // 取消
    await service.setGroupStatus(group.id, 2, reason: reason);
    if (context.mounted) Navigator.pop(context, 'return');
  }

  @override
  Widget build(BuildContext context) {
    final g = group;
    final share = AaSyncService.shareOfNonPayer(g.totalAmount);
    final d = DateTime.fromMillisecondsSinceEpoch(g.dateMs);
    String two(int v) => v.toString().padLeft(2, '0');

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AA 账单入账',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '${g.categoryEmoji} ${g.categoryName}${g.note.isEmpty ? '' : ' · ${g.note}'} · ${d.month}月${d.day}日 ${two(d.hour)}:${two(d.minute)} · 伙伴垫付',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Text('我的份额  ',
                    style: TextStyle(fontSize: 14, color: Colors.grey)),
                Text('¥ ${centsToText(share)}',
                    style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: kExpenseColor)),
                const Spacer(),
                const Text('总额 ¥ '),
                Text(centsToText(g.totalAmount),
                    style: const TextStyle(
                        fontSize: 13, decoration: TextDecoration.underline)),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '入账后仅计入应付账单，不在明细生成信息；付款账户在「去结算」时选择，结算完成后按应付明细逐条生成支出。',
              style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.5),
            ),
            const Divider(height: 20),
            Row(
              children: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: kExpenseColor),
                  onPressed: () => _returnBill(context),
                  child: const Text('退回'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style:
                        FilledButton.styleFrom(backgroundColor: kPrimaryColor),
                    onPressed: () => _confirm(context),
                    child: const Text('入账并确认'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
