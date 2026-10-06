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

  /// 收到伙伴确认信息后生成收入（挂账应收 = 伙伴份额，不计收支分类）。
  /// 幂等：组内已存在收入账单则跳过。
  Future<void> _ensureCompanionIncome(AaGroup g) async {
    final linked = await _db.billsOfAaGroup(g.id);
    for (final b in linked) {
      if (b.type == 1) return;
    }
    await _db.upsertBill(
      id: const Uuid().v4(),
      type: 1,
      amount: shareOfNonPayer(g.totalAmount),
      categoryId: kAaMarkerCategoryId,
      accountId: kAaCreditAccountId,
      dateMs: g.dateMs,
      note: 'AA应收 · ${g.categoryName}',
      aaGroupId: g.id,
    );
  }

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

  /// 我发起结算：核销全部未结算分摊组，并在本地生成挂账核销转账
  Future<void> settle({required String realAccountId, String note = ''}) async {
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
    final iReceive = net > 0;
    await _db.upsertBill(
      id: const Uuid().v4(),
      type: 2,
      amount: amount,
      accountId: iReceive ? kAaCreditAccountId : realAccountId,
      toAccountId: iReceive ? realAccountId : kAaCreditAccountId,
      dateMs: now,
      note: note.isEmpty ? (iReceive ? 'AA结算 · 收款' : 'AA结算 · 转出') : note,
      settlementId: id,
    );
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
  Future<void> cancelAaGroup({
    required String groupId,
    required bool deleteOwnerBill,
  }) async {
    final myUid = await _db.getMeta('myUid') ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    final group = await _db.getAaGroup(groupId);
    if (group == null) return;
    await (_db.update(_db.aaGroups)..where((t) => t.id.equals(groupId)))
        .write(AaGroupsCompanion(
      status: const Value(3),
      statusByUid: Value(myUid),
      statusAtMs: Value(now),
      statusNote: Value(deleteOwnerBill ? '已删除' : '已取消AA'),
      updatedAtMs: Value(now),
    ));
    final linked = await _db.billsOfAaGroup(groupId);
    for (final b in linked) {
      final isFullExpense = b.type == 0 && b.amount == group.totalAmount;
      if (isFullExpense && !deleteOwnerBill) {
        await _db.unlinkBillFromAaGroup(b.id); // 取消 AA：转普通账单
      } else {
        await _db.softDeleteBill(b.id); // 全额账单删除 / 挂账应收作废
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
      await _createSettlementBills(
        settlementId: id,
        receiverUid: m['receiverUid'] as String,
        amount: m['amount'] as int,
        dateMs: m['dateMs'] as int,
      );
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
        // 伙伴发起的 AA 账单：不静默建账，进「待入账」，由接收方选账户/分类/备注后入账
        // 我自己发起的账单（伙伴导出回传）：已确认则生成收入（收到应付方确认信息）
        if (ownerUid == myUid && (m['status'] as int? ?? 0) == 1) {
          final inserted = await _db.getAaGroup(id);
          if (inserted != null) await _ensureCompanionIncome(inserted);
        }
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
        // 我发起的账单被伙伴确认（回传 status=1）→ 生成收入账单
        if (local.ownerUid == myUid && newStatus == 1) {
          final fresh = await _db.getAaGroup(id);
          if (fresh != null) await _ensureCompanionIncome(fresh);
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

    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    await _db.setMeta(
        'lastImportAt', '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}');
    return '导入成功：新增 $newGroups 笔 AA 账单、更新 $updated、结算 $newSettles 笔';
  }

  /// 待入账的伙伴 AA 账单（对方发起、本机尚未生成份额账单、未退回未结算）
  Future<List<AaGroup>> pendingShareGroups() async {
    final myUid = await _db.getMeta('myUid') ?? '';
    if (myUid.isEmpty) return const [];
    final groups = await _db.getAllAaGroups();
    final bills = await _db.getAllBills();
    final linked = <String>{
      for (final b in bills)
        if (b.aaGroupId != null) b.aaGroupId!
    };
    return groups
        .where((g) =>
            g.ownerUid != myUid &&
            g.status == 0 &&
            !g.settled &&
            !linked.contains(g.id))
        .toList();
  }

  /// 接收方入账：用自己选的账户/分类/备注生成本机份额账单，并标记已确认
  Future<void> adoptShareBill({
    required AaGroup group,
    required String accountId,
    String? categoryId,
    required String note,
  }) async {
    await _db.upsertBill(
      id: const Uuid().v4(),
      type: 0,
      amount: shareOfNonPayer(group.totalAmount),
      categoryId: categoryId,
      accountId: accountId,
      dateMs: group.dateMs,
      note: note,
      aaGroupId: group.id,
    );
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

  /// 批量入账（长按批量确认）：默认模板 = AA挂账 + 按名称匹配分类 + 默认备注
  Future<void> adoptShareBillsDefault(
      List<AaGroup> groups, List<Category> categories) async {
    for (final g in groups) {
      await adoptShareBill(
        group: g,
        accountId: kAaCreditAccountId,
        categoryId: guessCategoryForName(g.categoryName, categories),
        note: g.note.isEmpty ? 'AA平分 · 伙伴垫付' : 'AA平分 · ${g.note}',
      );
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

  /// 结算落账：收款方 挂账→真实账户；转出方 真实账户→挂账（幂等）
  Future<void> _createSettlementBills({
    required String settlementId,
    required String receiverUid,
    required int amount,
    required int dateMs,
  }) async {
    if (await _db.hasSettlementBill(settlementId)) return;
    final myUid = await _db.getMeta('myUid') ?? '';
    if (myUid.isEmpty) return;
    final accounts = await _db.getAllAccounts();
    Account? real;
    for (final a in accounts) {
      if (a.id != kAaCreditAccountId) {
        real = a;
        break;
      }
    }
    if (real == null) return;
    final iReceive = receiverUid == myUid;
    await _db.upsertBill(
      id: const Uuid().v4(),
      type: 2,
      amount: amount,
      accountId: iReceive ? kAaCreditAccountId : real.id,
      toAccountId: iReceive ? real.id : kAaCreditAccountId,
      dateMs: dateMs,
      note: iReceive ? 'AA结算 · 收款' : 'AA结算 · 转出',
      settlementId: settlementId,
    );
  }
}
