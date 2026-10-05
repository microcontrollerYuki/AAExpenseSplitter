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
/// - 接收方：自动生成份额账单（50%，奇数分多出的 1 分归垫付方）记「AA挂账」
/// - 双方「AA挂账」余额互为相反数，差额 = |挂账余额|
class AaSyncService {
  AaSyncService(this._db);

  final AppDatabase _db;

  /// 非垫付方（伙伴垫付时）我的份额：奇数总额多出的 1 分归垫付方承担
  static int shareOfNonPayer(int total) => (total + 1) ~/ 2;

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

  /// 保存全额账单后调用：创建分摊组、关联账单、生成挂账应收
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
    // 挂账应收 = 伙伴份额（不计收支分类，不影响收支统计）
    await _db.upsertBill(
      id: const Uuid().v4(),
      type: 1,
      amount: shareOfNonPayer(totalAmount),
      categoryId: kAaMarkerCategoryId,
      accountId: kAaCreditAccountId,
      dateMs: dateMs,
      note: 'AA垫付 · 伙伴应付',
      aaGroupId: groupId,
    );
  }

  // ---------- 差额与结算 ----------

  /// 净应收（分）：>0 伙伴应转给我；<0 我应转给伙伴
  Future<int> computeNet() async {
    final myUid = await _db.getMeta('myUid') ?? '';
    final groups = await _db.getAllAaGroups();
    var net = 0;
    for (final g in groups) {
      if (g.settled) continue;
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

  /// 接收方确认 / 退回
  Future<void> setGroupStatus(String groupId, int status) async {
    final myUid = await _db.getMeta('myUid') ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.upsertAaGroup(AaGroupsCompanion(
      id: Value(groupId),
      status: Value(status),
      statusByUid: Value(myUid),
      statusAtMs: Value(now),
      updatedAtMs: Value(now),
    ));
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
          settled: Value(m['settled'] as bool? ?? false),
          settlementId: Value(m['settlementId'] as String?),
          createdAtMs: m['createdAtMs'] as int? ?? 0,
          updatedAtMs: incomingUpdated,
        ));
        // 伙伴发起的 AA 账单 → 在我的账本生成份额账单（挂账）
        if (ownerUid != myUid) {
          await _createShareBill(id, m);
        }
      } else if (incomingUpdated > local.updatedAtMs) {
        updated++;
        await _db.upsertAaGroup(AaGroupsCompanion(
          id: Value(id),
          status: Value(m['status'] as int? ?? local.status),
          statusByUid: Value(m['statusByUid'] as String?),
          statusAtMs: Value(m['statusAtMs'] as int?),
          settled: Value(m['settled'] as bool? ?? local.settled),
          settlementId: Value(m['settlementId'] as String?),
          updatedAtMs: Value(incomingUpdated),
        ));
      }
    }

    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    await _db.setMeta(
        'lastImportAt', '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}');
    return '导入成功：新增 $newGroups 笔 AA 账单、更新 $updated、结算 $newSettles 笔';
  }

  /// 伙伴垫付的 AA 账单 → 我的份额支出账单（记 AA挂账，不计入真实资产）
  Future<void> _createShareBill(String groupId, Map<String, Object?> m) async {
    final total = m['totalAmount'] as int;
    final catName = m['categoryName'] as String? ?? '';
    final categories = await _db.getAllCategories();
    String catId = 'cat_other_exp';
    for (final c in categories) {
      if (c.name == catName && c.kind == 0) {
        catId = c.id;
        break;
      }
    }
    final note = (m['note'] as String?) ?? '';
    await _db.upsertBill(
      id: const Uuid().v4(),
      type: 0,
      amount: shareOfNonPayer(total),
      categoryId: catId,
      accountId: kAaCreditAccountId,
      dateMs: m['dateMs'] as int,
      note: note.isEmpty ? 'AA · 伙伴垫付' : 'AA · $note',
      aaGroupId: groupId,
    );
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
