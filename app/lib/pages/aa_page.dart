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

class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.meta});

  final Map<String, String> meta;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myUid = meta['myUid'] ?? '';
    final partnerName = meta['partnerName'] ?? '伙伴';
    final groups = ref.watch(aaGroupsProvider).value ?? const <AaGroup>[];
    final settlements =
        ref.watch(settlementsProvider).value ?? const <Settlement>[];
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];

    var net = 0;
    var unsettled = 0;
    for (final g in groups) {
      if (g.settled) continue;
      unsettled++;
      final share = AaSyncService.shareOfNonPayer(g.totalAmount);
      net += g.payerUid == myUid ? share : -share;
    }
    final pendingMine = groups
        .where((g) => g.ownerUid != myUid && g.status == 0 && !g.settled)
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
        const SizedBox(height: 12),
        _groupsCard(groups, myUid),
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
              const Text('确认后将核销全部未结算 AA 账单，并在账本生成挂账核销转账。',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration:
                    const InputDecoration(labelText: '实际收/付款账户'),
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
                child: const Text('已完成转账')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await ref
            .read(aaSyncServiceProvider)
            .settle(realAccountId: selected, note: noteCtl.text.trim());
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
                  child: Text('上次导出：${meta['lastExportAt'] ?? '—'}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey))),
              Expanded(
                  child: Text('上次导入：${meta['lastImportAt'] ?? '—'}',
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
    try {
      final path =
          await ref.read(aaSyncServiceProvider).exportSyncFile();
      if (!context.mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path)],
        text: 'AA记账同步文件，请在 AA 页导入',
      ));
    } catch (e) {
      if (context.mounted) AaPage.showSnack(context, '导出失败：$e');
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    try {
      final f = await FilePicker.pickFile();
      final path = f?.path;
      if (path == null) return;
      final msg =
          await ref.read(aaSyncServiceProvider).importSyncFile(path);
      if (context.mounted) AaPage.showSnack(context, msg);
    } catch (_) {
      if (context.mounted) {
        AaPage.showSnack(context, '导入失败：口令不一致或文件损坏');
      }
    }
  }

  // ---- 待确认 ----

  Widget _pendingCard(
      BuildContext context, WidgetRef ref, List<AaGroup> pending) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('待你确认（${pending.length}）',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            for (final g in pending)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Text(g.categoryEmoji, style: const TextStyle(fontSize: 20)),
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
                            '总额 ¥ ${centsToText(g.totalAmount)} · 你的份额 ¥ ${centsToText(AaSyncService.shareOfNonPayer(g.totalAmount))}',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await ref
                            .read(aaSyncServiceProvider)
                            .setGroupStatus(g.id, 1);
                        if (context.mounted) {
                          AaPage.showSnack(context, '已确认，记得导出同步文件');
                        }
                      },
                      child: const Text('确认'),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                          foregroundColor: kExpenseColor),
                      onPressed: () async {
                        await ref
                            .read(aaSyncServiceProvider)
                            .setGroupStatus(g.id, 2);
                        if (context.mounted) {
                          AaPage.showSnack(context, '已退回，等待伙伴处理');
                        }
                      },
                      child: const Text('退回'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- AA 账单列表 ----

  Widget _groupsCard(List<AaGroup> groups, String myUid) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
              child: Text('AA 账单（${groups.length}）',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            if (groups.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                    child: Text('还没有 AA 账单，记账时打开「AA」开关试试',
                        style: TextStyle(color: Colors.grey, fontSize: 13))),
              )
            else
              for (final g in groups)
                ListTile(
                  dense: true,
                  leading:
                      Text(g.categoryEmoji, style: const TextStyle(fontSize: 20)),
                  title: Text(
                    '${g.payerUid == myUid ? '我垫付' : '伙伴垫付'} · ${g.categoryName}'
                    '${g.note.isEmpty ? '' : ' · ${g.note}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    '${_fmtDate(g.dateMs)} · 总额 ¥ ${centsToText(g.totalAmount)} · ${_statusText(g, myUid)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text(
                    '¥ ${centsToText(_myShare(g, myUid))}',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: g.payerUid == myUid
                            ? kPrimaryColor
                            : kExpenseColor),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  int _myShare(AaGroup g, String myUid) {
    final partnerShare = AaSyncService.shareOfNonPayer(g.totalAmount);
    return g.payerUid == myUid ? g.totalAmount - partnerShare : partnerShare;
  }

  String _statusText(AaGroup g, String myUid) {
    if (g.settled) return '已结算';
    switch (g.status) {
      case 1:
        return '已确认';
      case 2:
        return '已退回';
      default:
        return g.ownerUid == myUid ? '待伙伴确认' : '待我确认';
    }
  }

  String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}-${d.day.toString().padLeft(2, '0')}';
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
                    s.receiverUid == myUid ? 'AA结算 · 收款' : 'AA结算 · 转出',
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
              ),
          ],
        ),
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
