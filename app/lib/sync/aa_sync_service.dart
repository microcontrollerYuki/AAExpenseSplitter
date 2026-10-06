import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/presets.dart';
import 'aa_crypto.dart';

/// 无服务器 AA 同步：把本机 AA 全量状态加密导出为 .aas 文件，
/// 通过微信/QQ发给伙伴，对方导入后幂等合并。
///
/// 记账口径（与设计文档 §4.4 一致）：
/// - 垫付方：全额账单记真实账户；同时生成一笔「AA往来」挂账应收 = 伙伴份额
/// - 接收方：份额账单记「AA挂账」；奇数总额多出的 1 分归垫付方承担
/// - 双方「AA挂账」余额互为相反数，差额 = |挂账余额|
class AaSyncService {
  AaSyncService(this._db);

  final AppDatabase _db;

  /// 非垫付方（伙伴垫付时）我的份额：奇数总额多出的 1 分归垫付方承担
  static int shareOfNonPayer(int total) => total ~/ 2;

  // ---------- 配对 ----------

  Future<bool> isPaired() async => await _db.getMeta('pairSecret') != null;

  Future<void> setupPairing({
    required String myName,
    required String partnerName,
    required String secret,
  }) async {
    final myUid = await _db.getMeta('myUid') ?? const Uuid().v4();
    await _db.setMeta('myUid', myUid);
    await _db.setMeta('myName', myName);
    await _db.setMeta('partnerName', partnerName);
    await _db.setMeta('pairSecret', secret);
    final credit = await _db.getAccount(kAaCreditAccountId);
    if (credit == null) {
      await _db.upsertAccount(
        id: kAaCreditAccountId,
        name: 'AA挂账',
        emoji: '🤝',
        type: 4,
        initBalance: 0,
        includeNetWorth: false,
        sort: 99,
      );
    }
  }

  Future<void> resetPairing() async {
    for (final k in [
      'partnerName',
      'partnerUid',
      'pairSecret',
      'lastExportAt',
      'lastImportAt',
    ]) {
      await _db.deleteMeta(k);
    }
  }

  // ---------- 记一笔 AA（垫付方发起） ----------

  /// 保存全额账单后调用（新建与普通账单后补转 AA 共用）：
  /// 创建分摊组并关联账单。**不在此刻生成收入账单**（设计图：AA平分支出时
  /// 不应产生收入）——收入（挂账应收）在收到伙伴确认信息导入后由
  /// [_ensureCompanionIncome] 生成。
  Future<void> createAaBillFor({
    required String billId,
    required int totalAmount,
    required int dateMs,
    required String note,
    required String categoryName,
    required String categoryEmoji,
  }) async {
    final myUid = await _db.getMeta('myUid');
    if (myUid == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final groupId = const Uuid().v4();
    await _db.upsertAaGroup(AaGroupsCompanion.insert(
      id: groupId,
      ownerUid: myUid,
      payerUid: myUid,
      totalAmount: totalAmount,
      dateMs: dateMs,
      note: Value(note),
      categoryName: Value(categoryName),
      categoryEmoji: Value(categoryEmoji),
      createdAtMs: now,
      updatedAtMs: now,
    ));
    await _db.linkBillToAaGroup(billId, groupId);
  }

  /// 收到伙伴确认信息后：不再生成「AA应收」收入账单（收入统一在结算时
  /// 逐条生成，见 [settle] / [_createSettlementBills]），此处仅保留分摊组状态。
  // （保留注释锚点：_ensureCompanionIncome 已按 2026-10-06 需求移除）

  // ---------- 差额与结算 ----------

  /// 计入差额的分摊组：未结算、未退回（挂起待处理）、未取消（§4.3 退回处理期间不计差额）
  static bool countsTowardBalance(AaGroup g) => !g.settled && g.status <= 1;

  /// 净应收（分）：>0 伙伴应转给我；<0 我应转给伙伴
  Future<int> computeNet() async {
    final myUid = await _db.getMeta('myUid') ?? '';
    final groups = await _db.getAllAaGroups();
    var net = 0;
    for (final g in groups) {
      if (!countsTowardBalance(g)) continue;
      final partnerShare = shareOfNonPayer(g.totalAmount);
      net += g.payerUid == myUid ? partnerShare : -partnerShare;
    }
    return net;
  }

  /// 我发起结算：核销全部可结算分摊组，并**逐条**把应收/应付转成明细收支账单
  /// （图 2）——我垫付的每条生成收入（我收钱）、我应付的每条生成支出（我付钱），
  /// 账户统一为结算时选择的 [accountId]。不再生成任何转账。
  Future<void> settle({required String accountId, String note = ''}) async {
    final net = await computeNet();
    if (net == 0) return;
    final myUid = await _db.getMeta('myUid') ?? '';
    final partnerUid = await _db.getMeta('partnerUid');
    if (partnerUid == null || partnerUid.isEmpty) {
      throw Exception('尚未导入过伙伴的同步文件，无法确定收款方');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = const Uuid().v4();
    final receiverUid = net > 0 ? myUid : partnerUid;
    final amount = net.abs();
    // 核销前快照：本次结算覆盖的分摊组（逐条转明细的依据）
    final covered = [
      for (final g in await _db.getAllAaGroups())
        if (countsTowardBalance(g)) g
    ];
    await _db.upsertSettlement(SettlementsCompanion.insert(
      id: id,
      receiverUid: receiverUid,
      amount: amount,
      dateMs: now,
      cutoffMs: now,
      createdAtMs: now,
      note: Value(note),
    ));
    await _db.markSettledUpTo(now, id);
    await _db.setMeta(kAaSettleAccountKey, accountId);
    await _createSettlementBillsFromGroups(
        settlementId: id, covered: covered, accountId: accountId);
  }

  /// 接收方确认 / 退回（更新既有行，缺省字段走 update.write，避免 upsert 缺必填字段报错）
  /// 退回（status=2）可附一句理由，账单挂起不计差额，等待发起方处理（§4.3）
  Future<void> setGroupStatus(String groupId, int status,
      {String? reason}) async {
    final myUid = await _db.getMeta('myUid') ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.aaGroups)..where((t) => t.id.equals(groupId)))
        .write(AaGroupsCompanion(
      status: Value(status),
      statusByUid: Value(myUid),
      statusAtMs: Value(now),
      statusNote: Value(reason ?? ''),
      updatedAtMs: Value(now),
    ));
  }

  /// 发起方处理被退回的 AA 账单（§4.3 退回处理）：
  /// [deleteOwnerBill] = true 走「删除」（全额账单软删除）；
  /// false 走「取消 AA」（全额账单转普通账单，保留）。
  /// 分摊组置 status=3（已取消）作为墓碑同步给伙伴，对方导入后删除其份额账单。
  /// 删除AA属性 → 转普通收支记录（需求 2026-10-06）：
  /// 垫付账单转普通账单（isAa/aaGroupId 清空），分摊组置 status=3 同步给伙伴，
  /// 对方份额账单通过墓碑机制作废
  Future<void> cancelAaGroup({required String groupId}) async {
    final myUid = await _db.getMeta('myUid') ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    final group = await _db.getAaGroup(groupId);
    if (group == null) return;
    await (_db.update(_db.aaGroups)..where((t) => t.id.equals(groupId)))
        .write(AaGroupsCompanion(
      status: const Value(3),
      statusByUid: Value(myUid),
      statusAtMs: Value(now),
      statusNote: const Value('已转普通收支'),
      updatedAtMs: Value(now),
    ));
    final linked = await _db.billsOfAaGroup(groupId);
    for (final b in linked) {
      final isFullExpense = b.type == 0 && b.amount == group.totalAmount;
      if (isFullExpense) {
        await _db.unlinkBillFromAaGroup(b.id); // 转普通账单
      } else {
        await _db.softDeleteBill(b.id); // 挂账应收/旧份额账单作废
      }
    }
  }

  // ---------- 导出 ----------

  /// 导出全部 AA 状态（分摊组 + 结算）为加密文件，返回文件路径
  Future<String> exportSyncFile() async {
    final myUid = await _db.getMeta('myUid') ?? '';
    final myName = await _db.getMeta('myName') ?? '';
    final secret = await _db.getMeta('pairSecret');
    if (secret == null) throw Exception('尚未配对');
    final groups = await _db.getAllAaGroups();
    final settles = await _db.getAllSettlements();
    final payload = <String, Object?>{
      'format': 1,
      'fromUid': myUid,
      'fromName': myName,
      'exportedAtMs': DateTime.now().millisecondsSinceEpoch,
      'groups': [
        for (final g in groups)
          <String, Object?>{
            'id': g.id,
            'ownerUid': g.ownerUid,
            'payerUid': g.payerUid,
            'totalAmount': g.totalAmount,
            'dateMs': g.dateMs,
            'note': g.note,
            'categoryName': g.categoryName,
            'categoryEmoji': g.categoryEmoji,
            'status': g.status,
            'statusByUid': g.statusByUid,
            'statusAtMs': g.statusAtMs,
            'statusNote': g.statusNote,
            'settled': g.settled,
            'settlementId': g.settlementId,
            'createdAtMs': g.createdAtMs,
            'updatedAtMs': g.updatedAtMs,
          }
      ],
      'settlements': [
        for (final s in settles)
          <String, Object?>{
            'id': s.id,
            'receiverUid': s.receiverUid,
            'amount': s.amount,
            'dateMs': s.dateMs,
            'cutoffMs': s.cutoffMs,
            'note': s.note,
            'createdAtMs': s.createdAtMs,
          }
      ],
    };
    final content = await encryptToAasContent(payload, secret);
    final dir = await getTemporaryDirectory();
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'aasync_${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.aas';
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsString(content);
    await _db.setMeta(
        'lastExportAt', '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}');
    return f.path;
  }

  // ---------- 导入 ----------

  /// 导入伙伴发来的 .aas 文件并幂等合并，返回结果描述
  Future<String> importSyncFile(String path) async {
    final secret = await _db.getMeta('pairSecret');
    if (secret == null) throw Exception('尚未配对');
    final content = await File(path).readAsString();
    // 口令不一致会在这里抛出验签失败
    final data = await decryptAasContent(content, secret);
    final fromUid = data['fromUid'] as String? ?? '';
    final myUid = await _db.getMeta('myUid') ?? '';
    if (fromUid.isEmpty || fromUid == myUid) return '这是自己导出的文件，无需导入';
    await _db.setMeta('partnerUid', fromUid);
    await _db.setMeta('partnerName', (data['fromName'] as String?) ?? '伙伴');

    var newGroups = 0;
    var updated = 0;
    var newSettles = 0;
    // 结算落账任务：需在分摊组合并完成后再逐条生成（依赖该结算覆盖的分摊组）
    final settleJobs = <Map<String, Object?>>[];

    // 先应用结算（会顺带标记旧分摊组），再合并分摊组
    for (final s in (data['settlements'] as List? ?? [])) {
      final m = Map<String, Object?>.from(s as Map);
      final id = m['id'] as String;
      if (await _db.getSettlement(id) != null) continue;
      newSettles++;
      await _db.upsertSettlement(SettlementsCompanion.insert(
        id: id,
        receiverUid: m['receiverUid'] as String,
        amount: m['amount'] as int,
        dateMs: m['dateMs'] as int,
        cutoffMs: m['cutoffMs'] as int,
        createdAtMs: m['createdAtMs'] as int? ?? 0,
        note: Value((m['note'] as String?) ?? ''),
      ));
      await _db.markSettledUpTo(m['cutoffMs'] as int, id);
      settleJobs.add(m);
    }

    for (final g in (data['groups'] as List? ?? [])) {
      final m = Map<String, Object?>.from(g as Map);
      final id = m['id'] as String;
      final incomingUpdated = m['updatedAtMs'] as int? ?? 0;
      final local = await _db.getAaGroup(id);
      if (local == null) {
        final ownerUid = m['ownerUid'] as String;
        newGroups++;
        await _db.upsertAaGroup(AaGroupsCompanion.insert(
          id: id,
          ownerUid: ownerUid,
          payerUid: m['payerUid'] as String,
          totalAmount: m['totalAmount'] as int,
          dateMs: m['dateMs'] as int,
          note: Value((m['note'] as String?) ?? ''),
          categoryName: Value((m['categoryName'] as String?) ?? ''),
          categoryEmoji: Value((m['categoryEmoji'] as String?) ?? '🤝'),
          status: Value(m['status'] as int? ?? 0),
          statusByUid: Value(m['statusByUid'] as String?),
          statusAtMs: Value(m['statusAtMs'] as int?),
          statusNote: Value(m['statusNote'] as String?),
          settled: Value(m['settled'] as bool? ?? false),
          settlementId: Value(m['settlementId'] as String?),
          createdAtMs: m['createdAtMs'] as int? ?? 0,
          updatedAtMs: incomingUpdated,
        ));
        // 伙伴发起的 AA 账单：不静默建账，进「待入账」；确认后也只记应付，
        // 明细收支在结算时逐条生成（图 2 流程）
      } else if (incomingUpdated > local.updatedAtMs) {
        updated++;
        final newTotal = m['totalAmount'] as int;
        final newDateMs = m['dateMs'] as int;
        final newStatus = m['status'] as int? ?? local.status;
        // 更新既有行走 update.write：upsert(insertOnConflictUpdate) 缺必填字段会抛
        // InvalidDataException，即使行已存在也先做 INSERT 完整性校验
        await (_db.update(_db.aaGroups)..where((t) => t.id.equals(id)))
            .write(AaGroupsCompanion(
          totalAmount: Value(newTotal),
          dateMs: Value(newDateMs),
          note: Value((m['note'] as String?) ?? ''),
          categoryName: Value((m['categoryName'] as String?) ?? ''),
          categoryEmoji: Value((m['categoryEmoji'] as String?) ?? '🤝'),
          status: Value(newStatus),
          statusByUid: Value(m['statusByUid'] as String?),
          statusAtMs: Value(m['statusAtMs'] as int?),
          statusNote: Value(m['statusNote'] as String?),
          settled: Value(m['settled'] as bool? ?? local.settled),
          settlementId: Value(m['settlementId'] as String?),
          updatedAtMs: Value(incomingUpdated),
        ));
        // 伙伴改了金额/日期 → 同步更新本机份额账单（金额=新份额，日期跟随）
        if (local.ownerUid != myUid &&
            newStatus <= 1 &&
            (local.totalAmount != newTotal || local.dateMs != newDateMs)) {
          final linked = await _db.billsOfAaGroup(id);
          for (final b in linked) {
            if (b.type == 0) {
              await _db.updateBillAmountAndDate(
                  b.id, shareOfNonPayer(newTotal), newDateMs);
            }
          }
        }
        // 伙伴「取消 AA / 删除」（status=3 墓碑）→ 同步作废我的份额账单（§4.6 双方软删除）
        if (local.ownerUid != myUid && newStatus == 3) {
          final linked = await _db.billsOfAaGroup(id);
          for (final b in linked) {
            await _db.softDeleteBill(b.id);
          }
        }
      }
    }

    // 分摊组合并完成后再落账结算明细（与应付/应收逐条对应）
    for (final m in settleJobs) {
      await _createSettlementBills(
        settlementId: m['id'] as String,
        receiverUid: m['receiverUid'] as String,
        amount: m['amount'] as int,
        dateMs: m['dateMs'] as int,
      );
    }

    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    await _db.setMeta(
        'lastImportAt', '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}');
    return '导入成功：新增 $newGroups 笔 AA 账单、更新 $updated、结算 $newSettles 笔';
  }

  /// 待入账的伙伴 AA 账单（对方发起、尚未入账确认、未退回未结算）。
  /// 入账不生成明细账单，因此以分摊组状态为准（不再看账单关联）
  Future<List<AaGroup>> pendingShareGroups() async {
    final myUid = await _db.getMeta('myUid') ?? '';
    if (myUid.isEmpty) return const [];
    final groups = await _db.getAllAaGroups();
    return groups
        .where((g) =>
            g.ownerUid != myUid && g.status == 0 && !g.settled)
        .toList();
  }

  /// 接收方入账（图 2）：不生成明细账单、不选择账户/分类——应付只在 AA 页跟踪；
  /// 付款账户在「去结算」时选择，结算完成后按应付明细逐条生成支出账单
  Future<void> confirmShare({required AaGroup group}) async {
    await setGroupStatus(group.id, 1);
  }

  /// 垫付方修改 AA 账单后：更新分摊组，状态回「待伙伴确认」（设计图「待修改」），
  /// 并撤回已生成的收入账单（回到未确认状态，伙伴重新确认后再生成）
  Future<void> ownerUpdatedAaGroup({
    required String groupId,
    required int newTotal,
    required int dateMs,
    required String note,
    required String categoryName,
    required String categoryEmoji,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.aaGroups)..where((t) => t.id.equals(groupId)))
        .write(AaGroupsCompanion(
      totalAmount: Value(newTotal),
      dateMs: Value(dateMs),
      note: Value(note),
      categoryName: Value(categoryName),
      categoryEmoji: Value(categoryEmoji),
      status: const Value(0),
      statusByUid: const Value<String?>(null),
      statusAtMs: const Value<int?>(null),
      statusNote: const Value<String?>(null),
      updatedAtMs: Value(now),
    ));
    final linked = await _db.billsOfAaGroup(groupId);
    for (final b in linked) {
      if (b.type == 1) {
        await _db.softDeleteBill(b.id);
      }
    }
  }

  /// 批量入账（长按批量确认）：与 [confirmShare] 同语义，只确认不建明细
  Future<void> adoptShareBillsDefault(
      List<AaGroup> groups, List<Category> categories) async {
    for (final g in groups) {
      await confirmShare(group: g);
    }
  }

  /// 按分类名匹配本地分类（接收方入账默认模板用）
  static String? guessCategoryForName(String? name, List<Category> categories) {
    if (name == null || name.isEmpty) return null;
    for (final c in categories) {
      if (c.kind == 0 && c.name == name) return c.id;
    }
    return null;
  }

  /// 结算账户偏好（[settle] 选定后保存；导入伙伴结算时沿用）
  static const kAaSettleAccountKey = 'aaSettleAccountId';

  /// 结算落账账户：优先沿用上次结算选择，否则取第一个真实账户；
  /// 无真实账户时返回 null（跳过落账）
  Future<String?> _preferredSettleAccount() async {
    final accounts = await _db.getAllAccounts();
    final preferred = await _db.getMeta(kAaSettleAccountKey);
    for (final a in accounts) {
      if (a.id == preferred) return a.id;
    }
    for (final a in accounts) {
      if (a.id != kAaCreditAccountId) return a.id;
    }
    return null;
  }

  /// 逐条生成结算收支账单：我垫付的组 → 收入（我收钱）；我应付的组 → 支出（我付钱）。
  /// 结算账单只带 settlementId（不挂 aaGroupId），与分摊组一一对应、幂等。
  Future<void> _createSettlementBillsFromGroups({
    required String settlementId,
    required List<AaGroup> covered,
    required String accountId,
  }) async {
    if (await _db.hasSettlementBill(settlementId)) return;
    final myUid = await _db.getMeta('myUid') ?? '';
    if (myUid.isEmpty) return;
    final categories = await _db.getAllCategories();
    for (final g in covered) {
      final iAmPayer = g.payerUid == myUid;
      final share = shareOfNonPayer(g.totalAmount);
      if (share <= 0) continue;
      await _db.upsertBill(
        id: const Uuid().v4(),
        type: iAmPayer ? 1 : 0,
        categoryId: iAmPayer
            ? 'inc_other'
            : (guessCategoryForName(g.categoryName, categories) ??
                'cat_other_exp'),
        amount: share,
        accountId: accountId,
        dateMs: g.dateMs,
        note: 'AA平分：${g.categoryName}${g.note.isEmpty ? '' : ' · ${g.note}'}',
        settlementId: settlementId,
      );
    }
  }

  /// 结算落账（导入伙伴结算文件时）：按该结算覆盖的分摊组逐条生成收支账单；
  /// 旧数据缺明细时退回按净额记一笔（幂等）
  Future<void> _createSettlementBills({
    required String settlementId,
    required String receiverUid,
    required int amount,
    required int dateMs,
  }) async {
    if (await _db.hasSettlementBill(settlementId)) return;
    final myUid = await _db.getMeta('myUid') ?? '';
    if (myUid.isEmpty) return;
    final covered = [
      for (final g in await _db.getAllAaGroups())
        if (g.settlementId == settlementId) g
    ];
    final accountId = await _preferredSettleAccount();
    if (accountId == null) return; // 无真实账户：跳过落账
    if (covered.isNotEmpty) {
      await _createSettlementBillsFromGroups(
          settlementId: settlementId, covered: covered, accountId: accountId);
      return;
    }
    // 兜底：没有分摊组明细（旧版本结算）→ 按净额记一笔收入/支出
    final iReceive = receiverUid == myUid;
    await _db.upsertBill(
      id: const Uuid().v4(),
      type: iReceive ? 1 : 0,
      amount: amount,
      categoryId: iReceive ? 'inc_other' : 'cat_other_exp',
      accountId: accountId,
      dateMs: dateMs,
      note: 'AA平分：结算',
      settlementId: settlementId,
    );
  }
}
