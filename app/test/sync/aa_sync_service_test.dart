import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/sync/aa_crypto.dart';
import 'package:aa_expense_splitter/sync/aa_sync_service.dart';

import '../helpers/test_support.dart';

void main() {
  late TestAppDatabase db;
  late AaSyncService svc;
  late FakePathProvider pathProvider;

  setUp(() async {
    pathProvider = FakePathProvider();
    PathProviderPlatform.instance = pathProvider;
    db = TestAppDatabase();
    svc = AaSyncService(db);
    await db.getAllAccounts(); // 触发播种
  });

  tearDown(() async {
    await db.close();
    pathProvider.cleanup();
  });

  Future<void> pair({
    String myName = 'Yui',
    String partnerName = 'Partner',
    String secret = 'share-secret-1',
  }) =>
      svc.setupPairing(
          myName: myName, partnerName: partnerName, secret: secret);

  group('shareOfNonPayer 奇数分多出的 1 分归垫付方', () {
    test('偶数对半', () {
      expect(AaSyncService.shareOfNonPayer(100), 50);
      expect(AaSyncService.shareOfNonPayer(0), 0);
    });

    test('奇数向下取整（非垫付方份额，多出的 1 分归垫付方）', () {
      expect(AaSyncService.shareOfNonPayer(101), 50);
      expect(AaSyncService.shareOfNonPayer(1), 0);
    });
  });

  group('配对', () {
    test('isPaired 随 setupPairing 变化', () async {
      expect(await svc.isPaired(), isFalse);
      await pair();
      expect(await svc.isPaired(), isTrue);
    });

    test('setupPairing 写入元数据并创建 AA挂账 账户', () async {
      await pair();
      expect((await db.getMeta('myUid'))!, isNotEmpty);
      expect(await db.getMeta('myName'), 'Yui');
      expect(await db.getMeta('partnerName'), 'Partner');
      expect(await db.getMeta('pairSecret'), 'share-secret-1');
      final credit = await db.getAccount(kAaCreditAccountId);
      expect(credit, isNotNull);
      expect(credit!.type, 4);
      expect(credit.includeNetWorth, isFalse);
    });

    test('重复 setupPairing 保留既有 myUid 且不重复建账户', () async {
      await pair();
      final uid1 = await db.getMeta('myUid');
      await pair(myName: 'Yui2');
      expect(await db.getMeta('myUid'), uid1);
      final accounts = await db.getAllAccounts();
      expect(accounts.where((a) => a.id == kAaCreditAccountId).length, 1);
    });

    test('resetPairing 清除配对元数据', () async {
      await pair();
      await svc.resetPairing();
      expect(await svc.isPaired(), isFalse);
      expect(await db.getMeta('partnerName'), isNull);
      expect(await db.getMeta('partnerUid'), isNull);
      expect(await db.getMeta('pairSecret'), isNull);
      expect(await db.getMeta('lastExportAt'), isNull);
      expect(await db.getMeta('lastImportAt'), isNull);
    });
  });

  group('createAaBillFor（垫付方发起）', () {
    test('未配对（无 myUid）时不产生任何数据', () async {
      await db.upsertBill(
          id: 'bill-x',
          type: 0,
          amount: 9900,
          accountId: 'acc_cash',
          dateMs: 1000);
      await svc.createAaBillFor(
        billId: 'bill-x',
        totalAmount: 9900,
        dateMs: 1000,
        note: '晚饭',
        categoryName: '餐饮',
        categoryEmoji: '🍜',
      );
      expect(await db.getAllAaGroups(), isEmpty);
      // 账单未被关联 AA
      final bills = await db.watchAllBills().first;
      expect(bills.first.aaGroupId, isNull);
    });

    test('配对后创建分摊组 + 关联账单；此刻不生成收入账单（确认后才生成）', () async {
      await pair();
      await db.upsertBill(
          id: 'bill-1',
          type: 0,
          amount: 9900,
          accountId: 'acc_cash',
          dateMs: 1000,
          note: '晚饭');
      await svc.createAaBillFor(
        billId: 'bill-1',
        totalAmount: 9900,
        dateMs: 1000,
        note: '晚饭',
        categoryName: '餐饮',
        categoryEmoji: '🍜',
      );

      final groups = await db.getAllAaGroups();
      expect(groups.length, 1);
      final g = groups.first;
      final myUid = await db.getMeta('myUid');
      expect(g.payerUid, myUid);
      expect(g.ownerUid, myUid);
      expect(g.totalAmount, 9900);
      expect(g.note, '晚饭');
      expect(g.categoryName, '餐饮');
      expect(g.settled, isFalse);

      // 原账单被关联
      final bills = await db.watchAllBills().first;
      final linked = bills.firstWhere((b) => b.id == 'bill-1');
      expect(linked.aaGroupId, g.id);
      expect(linked.isAa, isTrue);

      // 设计图：记 AA 账单时不生成收入账单——此时只有这一笔账单
      expect(bills.length, 1);
    });
  });

  group('computeNet / settle', () {
    test('computeNet：垫付方 +份额，非垫付方 -份额，已结算跳过', () async {
      await pair();
      final myUid = (await db.getMeta('myUid'))!;
      Future<void> group(String id, String payer, int total,
              {bool settled = false}) =>
          db.upsertAaGroup(AaGroupsCompanion.insert(
            id: id,
            ownerUid: payer,
            payerUid: payer,
            totalAmount: total,
            dateMs: 10,
            createdAtMs: 1,
            updatedAtMs: 1,
            settled: Value(settled),
          ));
      await group('g-me', myUid, 1000);
      await group('g-partner', 'partner-uid', 500);
      await group('g-done', myUid, 999999, settled: true);
      // 500 - 505... 期望 = +500(我垫付1000的一半... 等一下：我垫付得 +份额(500)，伙伴垫付扣 250
      expect(await svc.computeNet(), 500 - 250);
    });

    test('settle：净额为 0 直接返回不产生数据', () async {
      await pair();
      await svc.settle(accountId: 'acc_cash');
      expect(await db.getAllSettlements(), isEmpty);
    });

    test('settle：未导入过伙伴文件（无 partnerUid）时抛异常', () async {
      await pair();
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: (await db.getMeta('myUid'))!,
        payerUid: (await db.getMeta('myUid'))!,
        totalAmount: 1000,
        dateMs: 10,
        createdAtMs: 1,
        updatedAtMs: 1,
      ));
      expect(() => svc.settle(accountId: 'acc_cash'), throwsException);
    });

    test('settle：我收款时逐条生成收入账单（入到选定账户）并核销分组', () async {
      await pair();
      final myUid = (await db.getMeta('myUid'))!;
      await db.setMeta('partnerUid', 'partner-uid');
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: myUid,
        payerUid: myUid,
        totalAmount: 1000,
        dateMs: 10,
        note: const Value('晚饭'),
        categoryName: const Value('餐饮'),
        categoryEmoji: const Value('🍜'),
        createdAtMs: 1,
        updatedAtMs: 1,
      ));

      await svc.settle(accountId: 'acc_bank', note: '微信已转');

      final settles = await db.getAllSettlements();
      expect(settles.length, 1);
      expect(settles.first.receiverUid, myUid);
      expect(settles.first.amount, 500);
      expect(settles.first.note, '微信已转');
      // 分组被核销
      expect((await db.getAaGroup('g1'))!.settled, isTrue);
      // 逐条生成收入（我垫付这条 → 我收钱），不再生成转账
      final bills = await db.watchAllBills().first;
      final income = bills.firstWhere((b) => b.settlementId != null);
      expect(income.type, 1);
      expect(income.amount, 500);
      expect(income.accountId, 'acc_bank');
      expect(income.toAccountId, isNull);
      expect(income.categoryId, 'inc_other');
      expect(income.note, 'AA平分：餐饮 · 晚饭');
    });

    test('settle：我付款时逐条生成支出账单（从选定账户付款）', () async {
      await pair();
      final myUid = (await db.getMeta('myUid'))!;
      await db.setMeta('partnerUid', 'partner-uid');
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: 'partner-uid',
        payerUid: 'partner-uid',
        totalAmount: 1000,
        dateMs: 10,
        createdAtMs: 1,
        updatedAtMs: 1,
      ));

      await svc.settle(accountId: 'acc_cash');

      final settles = await db.getAllSettlements();
      expect(settles.first.receiverUid, 'partner-uid');
      // 逐条生成支出（我应付这条 → 我付钱），不再生成转账
      final bills = await db.watchAllBills().first;
      final expense = bills.firstWhere((b) => b.settlementId != null);
      expect(expense.type, 0);
      expect(expense.amount, 500);
      expect(expense.accountId, 'acc_cash');
      expect(expense.toAccountId, isNull);
      expect(expense.note, 'AA平分：'); // 无分类名/备注时的兜底文案
    });
  });

  group('setGroupStatus', () {
    test('更新状态字段（update.write 语义）', () async {
      await pair();
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: 'partner-uid',
        payerUid: 'partner-uid',
        totalAmount: 100,
        dateMs: 10,
        createdAtMs: 1,
        updatedAtMs: 1,
      ));
      await svc.setGroupStatus('g1', 1);
      var g = await db.getAaGroup('g1');
      expect(g!.status, 1);
      expect(g.statusByUid, await db.getMeta('myUid'));
      expect(g.statusAtMs, isNotNull);

      await svc.setGroupStatus('g1', 2);
      g = await db.getAaGroup('g1');
      expect(g!.status, 2);

      // 目标不存在时静默无操作
      await svc.setGroupStatus('ghost', 1);
      expect(await db.getAaGroup('ghost'), isNull);
    });
  });

  group('exportSyncFile', () {
    test('未配对抛异常', () async {
      expect(() => svc.exportSyncFile(), throwsException);
    });

    test('导出加密文件并可解密回完整 payload', () async {
      await pair();
      final myUid = await db.getMeta('myUid');
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: myUid!,
        payerUid: myUid,
        totalAmount: 1234,
        dateMs: 77,
        note: Value('午餐'),
        categoryName: Value('餐饮'),
        categoryEmoji: Value('🍜'),
        createdAtMs: 1,
        updatedAtMs: 2,
      ));
      await db.upsertSettlement(SettlementsCompanion.insert(
        id: 's1',
        receiverUid: myUid,
        amount: 617,
        dateMs: 88,
        cutoffMs: 80,
        createdAtMs: 3,
        note: const Value('微信转账'),
      ));

      final path = await svc.exportSyncFile();
      expect(path, endsWith('.aas'));
      expect(File(path).existsSync(), isTrue);
      expect(basenameLike(path), startsWith('aasync_'));

      final payload = await decryptAasContent(
          File(path).readAsStringSync(), 'share-secret-1');
      expect(payload['fromUid'], myUid);
      expect(payload['fromName'], 'Yui');
      expect(payload['format'], 1);
      final groups = payload['groups'] as List;
      expect((groups.first as Map)['id'], 'g1');
      final settles = payload['settlements'] as List;
      expect((settles.first as Map)['id'], 's1');
      // 导出时间元数据
      expect(await db.getMeta('lastExportAt'), isNotNull);
    });
  });

  group('importSyncFile', () {
    test('未配对抛异常', () async {
      final f = File('${pathProvider.tempDir.path}/x.aas')
        ..writeAsStringSync('whatever');
      expect(() => svc.importSyncFile(f.path), throwsException);
    });

    test('口令不一致时解密失败抛出', () async {
      await pair();
      final content = await encryptToAasContent({'fromUid': 'other'}, '别的口令');
      final f = File('${pathProvider.tempDir.path}/bad.aas')
        ..writeAsStringSync(content);
      expect(() => svc.importSyncFile(f.path), throwsA(anything));
    });

    test('导入自己导出的文件被拒绝', () async {
      await pair();
      final path = await svc.exportSyncFile();
      final msg = await svc.importSyncFile(path);
      expect(msg, contains('自己导出'));
    });

    test('双机同步：A 垫付记账 → B 待入账确认后生成份额账单', () async {
      // --- A 机 ---
      final dbA = TestAppDatabase();
      final svcA = AaSyncService(dbA);
      await dbA.getAllAccounts();
      await svcA.setupPairing(
          myName: '小A', partnerName: '小B', secret: 'the-secret');
      await dbA.upsertBill(
          id: 'billA',
          type: 0,
          amount: 10001,
          accountId: 'acc_wechat',
          dateMs: 500,
          note: '火锅');
      await svcA.createAaBillFor(
        billId: 'billA',
        totalAmount: 10001,
        dateMs: 500,
        note: '火锅',
        categoryName: '餐饮',
        categoryEmoji: '🍜',
      );
      final exported = await svcA.exportSyncFile();

      // --- B 机（本测试的 db/svc）---
      await svc.setupPairing(
          myName: '小B', partnerName: '小A', secret: 'the-secret');
      final msg = await svc.importSyncFile(exported);
      expect(msg, contains('新增 1 笔'));
      expect(await db.getMeta('partnerUid'), await dbA.getMeta('myUid'));
      expect(await db.getMeta('partnerName'), '小A');
      expect(await db.getMeta('lastImportAt'), isNotNull);

      // 不静默建账：进「待入账」，由接收方选账户/分类/备注后入账
      expect(await db.watchAllBills().first, isEmpty);
      final pending = await svc.pendingShareGroups();
      expect(pending, hasLength(1));

      // 接收方入账：只确认、不建明细账单（图 2）——份额账单在结算时逐条生成
      await svc.confirmShare(group: pending.single);
      expect((await db.getAaGroup(pending.single.id))!.status, 1);
      expect(await db.watchAllBills().first, isEmpty);

      // B 视角净额：伙伴垫付 → 应付 -50.00
      expect(await svc.computeNet(), -5000);

      // 幂等：重导同一文件不新增
      final msg2 = await svc.importSyncFile(exported);
      expect(msg2, contains('新增 0 笔'));
      expect(await db.watchAllBills().first, isEmpty);

      await dbA.close();
    });

    test('导入含结算的文件：逐条生成收支账单且幂等', () async {
      await pair();
      final myUid = await db.getMeta('myUid');
      final payload = {
        'format': 1,
        'fromUid': 'partner-uid',
        'fromName': '伙伴',
        'exportedAtMs': 1,
        'settlements': [
          {
            'id': 'settle-1',
            'receiverUid': myUid, // 我收款
            'amount': 1234,
            'dateMs': 100,
            'cutoffMs': 90,
            'note': '',
            'createdAtMs': 1,
          }
        ],
        'groups': [
          {
            'id': 'pg1',
            'ownerUid': 'partner-uid',
            'payerUid': 'partner-uid',
            'totalAmount': 2468,
            'dateMs': 10,
            'note': '晚餐',
            'categoryName': '餐饮',
            'categoryEmoji': '🍜',
            'status': 0,
            'statusByUid': null,
            'statusAtMs': null,
            // 结算先于分组应用（markSettledUpTo 只核销本地已有组），
            // 导出方结算后导出的新组本身即携带 settled=true
            'settled': true,
            'settlementId': 'settle-1',
            'createdAtMs': 1,
            'updatedAtMs': 5,
          }
        ],
      };
      final f = File('${pathProvider.tempDir.path}/partner.aas')
        ..writeAsStringSync(await encryptToAasContent(payload, 'share-secret-1'));

      await svc.importSyncFile(f.path);

      // 结算落账：我收款 → 挂账→真实账户
      var bills = await db.watchAllBills().first;
      final settleBills =
          bills.where((b) => b.settlementId == 'settle-1').toList();
      // 逐条落账（图 2）：pg1 伙伴垫付 → 我应付 → 一笔支出，账户=结算落账账户
      expect(settleBills.length, 1);
      expect(settleBills.first.type, 0);
      expect(settleBills.first.amount, 1234);
      expect(settleBills.first.accountId, 'acc_cash');
      expect(settleBills.first.toAccountId, isNull);
      // cutoff 核销了伙伴的组
      expect((await db.getAaGroup('pg1'))!.settled, isTrue);

      // 幂等：再导一次不重复生成结算账单
      await svc.importSyncFile(f.path);
      bills = await db.watchAllBills().first;
      expect(bills.where((b) => b.settlementId == 'settle-1').length, 1);
    });

    test('导入结算时若本机无真实账户则跳过落账', () async {
      await pair();
      // 删掉全部真实账户，仅剩 AA挂账
      for (final a in await db.getAllAccounts()) {
        if (a.id != kAaCreditAccountId) await db.deleteAccount(a.id);
      }
      final payload = {
        'format': 1,
        'fromUid': 'partner-uid',
        'fromName': '伙伴',
        'exportedAtMs': 1,
        'settlements': [
          {
            'id': 'settle-noacc',
            'receiverUid': 'partner-uid',
            'amount': 100,
            'dateMs': 100,
            'cutoffMs': 90,
            'note': '',
            'createdAtMs': 1,
          }
        ],
        'groups': [],
      };
      final f = File('${pathProvider.tempDir.path}/noacc.aas')
        ..writeAsStringSync(await encryptToAasContent(payload, 'share-secret-1'));
      await svc.importSyncFile(f.path);
      expect((await db.getAllSettlements()).length, 1);
      expect(await db.watchAllBills().first, isEmpty);
    });

    test('分摊组更新：updatedAtMs 更大才更新，缺失字段取默认', () async {
      await pair();
      final payload = {
        'format': 1,
        'fromUid': 'partner-uid',
        'fromName': '伙伴',
        'exportedAtMs': 1,
        'groups': [
          {
            'id': 'pg2',
            'ownerUid': 'partner-uid',
            'payerUid': 'partner-uid',
            'totalAmount': 500,
            'dateMs': 10,
            // note / categoryName / categoryEmoji / status / settled /
            // settlementId / createdAtMs 全部缺失 → 走默认值分支
            'updatedAtMs': 10,
          }
        ],
        'settlements': null, // 缺 settlements → ?? [] 分支
      };
      final f = File('${pathProvider.tempDir.path}/p2.aas')
        ..writeAsStringSync(await encryptToAasContent(payload, 'share-secret-1'));
      await svc.importSyncFile(f.path);

      var g = await db.getAaGroup('pg2');
      expect(g!.note, '');
      expect(g.categoryName, '');
      expect(g.categoryEmoji, '🤝');
      expect(g.status, 0);
      expect(g.settled, isFalse);
      expect(g.createdAtMs, 0);
      expect(g.updatedAtMs, 10);
      // 伙伴发起 → 进「待入账」，不静默建账
      expect(await db.watchAllBills().first, isEmpty);
      expect(await svc.pendingShareGroups(), hasLength(1));

      // 更新分支：更大 updatedAtMs
      payload['groups'] = [
        {
          'id': 'pg2',
          'ownerUid': 'partner-uid',
          'payerUid': 'partner-uid',
          'totalAmount': 500,
          'dateMs': 10,
          'status': 1,
          'statusByUid': 'partner-uid',
          'statusAtMs': 99,
          'settled': false,
          'settlementId': null,
          'note': '',
          'categoryName': '',
          'categoryEmoji': '',
          'createdAtMs': 1,
          'updatedAtMs': 20,
        }
      ];
      f.writeAsStringSync(await encryptToAasContent(payload, 'share-secret-1'));
      final msg = await svc.importSyncFile(f.path);
      expect(msg, contains('更新 1'));
      g = await db.getAaGroup('pg2');
      expect(g!.status, 1);
      expect(g.updatedAtMs, 20);
      // 未入账前不产生账单，重复导入/更新也不会多出账单
      expect(await db.watchAllBills().first, isEmpty);
    });

    test('导入自己 uid 拥有的新分组时不生成份额账单', () async {
      await pair();
      final myUid = await db.getMeta('myUid');
      final payload = {
        'format': 1,
        'fromUid': 'partner-uid', // 伙伴转来，但组 owner 是我（换机场景）
        'fromName': '伙伴',
        'exportedAtMs': 1,
        'groups': [
          {
            'id': 'mine-1',
            'ownerUid': myUid,
            'payerUid': myUid,
            'totalAmount': 800,
            'dateMs': 10,
            'note': '',
            'categoryName': '',
            'categoryEmoji': '',
            'createdAtMs': 1,
            'updatedAtMs': 5,
          }
        ],
      };
      final f = File('${pathProvider.tempDir.path}/p3.aas')
        ..writeAsStringSync(await encryptToAasContent(payload, 'share-secret-1'));
      await svc.importSyncFile(f.path);
      expect((await db.getAllAaGroups()).length, 1);
      expect(await db.watchAllBills().first, isEmpty); // 不生成份额账单
    });
  });

  group('退回挂起 / 取消与删除（§4.3 退回处理）', () {
    test('setGroupStatus 退回可附理由', () async {
      await pair();
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: 'uid-partner',
        payerUid: 'uid-partner',
        totalAmount: 1000,
        dateMs: 10,
        createdAtMs: 1,
        updatedAtMs: 1,
      ));
      await svc.setGroupStatus('g1', 2, reason: '这笔应该按 60/40 分');
      final g = (await db.getAaGroup('g1'))!;
      expect(g.status, 2);
      expect(g.statusNote, '这笔应该按 60/40 分');
    });

    test('computeNet 不计入退回（2）与已取消（3）的分摊组', () async {
      await pair();
      final myUid = (await db.getMeta('myUid'))!;
      Future<void> add(String id, int total, int status, String payer) =>
          db.upsertAaGroup(AaGroupsCompanion.insert(
            id: id,
            ownerUid: payer,
            payerUid: payer,
            totalAmount: total,
            dateMs: 10,
            status: Value(status),
            createdAtMs: 1,
            updatedAtMs: 1,
          ));
      await add('g-ok', 1000, 1, myUid); // 计入：+500
      await add('g-returned', 8000, 2, myUid); // 退回挂起：不计
      await add('g-cancelled', 8000, 3, myUid); // 已取消：不计
      expect(AaSyncService.countsTowardBalance((await db.getAaGroup('g-ok'))!),
          isTrue);
      expect(
          AaSyncService.countsTowardBalance(
              (await db.getAaGroup('g-returned'))!),
          isFalse);
      expect(await svc.computeNet(), 500);
    });

    test('markSettledUpTo 不核销退回挂起/已取消的分摊组', () async {
      await pair();
      final myUid = (await db.getMeta('myUid'))!;
      Future<void> add(String id, int status) =>
          db.upsertAaGroup(AaGroupsCompanion.insert(
            id: id,
            ownerUid: myUid,
            payerUid: myUid,
            totalAmount: 1000,
            dateMs: 10,
            status: Value(status),
            createdAtMs: 1,
            updatedAtMs: 1,
          ));
      await add('g-ok', 1);
      await add('g-returned', 2);
      await add('g-cancelled', 3);
      await db.markSettledUpTo(100, 'settle-1');
      expect((await db.getAaGroup('g-ok'))!.settled, isTrue);
      expect((await db.getAaGroup('g-returned'))!.settled, isFalse);
      expect((await db.getAaGroup('g-cancelled'))!.settled, isFalse);
    });

    test('cancelAaGroup 取消 AA：垫付账单转普通账单、挂账应收作废', () async {
      await pair();
      await db.upsertBill(
          id: 'bill-full',
          type: 0,
          amount: 10001,
          accountId: 'acc_cash',
          dateMs: 10,
          note: '火锅');
      await svc.createAaBillFor(
        billId: 'bill-full',
        totalAmount: 10001,
        dateMs: 10,
        note: '火锅',
        categoryName: '餐饮',
        categoryEmoji: '🍜',
      );
      final gid = (await db.getAllAaGroups()).single.id;

      await svc.cancelAaGroup(groupId: gid, deleteOwnerBill: false);

      expect((await db.getAaGroup(gid))!.status, 3);
      final full = (await db.watchAllBills().first)
          .firstWhere((b) => b.id == 'bill-full');
      expect(full.deletedAt, isNull);
      expect(full.isAa, isFalse); // 转普通账单
      expect(full.aaGroupId, isNull);
      // 新语义：记 AA 时不生成收入账单，故无应收需要作废
      final others = (await (db.select(db.bills)).get())
          .where((b) => b.id != 'bill-full');
      expect(others, isEmpty);
    });

    test('cancelAaGroup 删除：垫付账单软删除', () async {
      await pair();
      await db.upsertBill(
          id: 'bill-full',
          type: 0,
          amount: 10001,
          accountId: 'acc_cash',
          dateMs: 10,
          note: '火锅');
      await svc.createAaBillFor(
        billId: 'bill-full',
        totalAmount: 10001,
        dateMs: 10,
        note: '火锅',
        categoryName: '餐饮',
        categoryEmoji: '🍜',
      );
      final gid = (await db.getAllAaGroups()).single.id;

      await svc.cancelAaGroup(groupId: gid, deleteOwnerBill: true);

      expect((await db.getAaGroup(gid))!.status, 3);
      final all = await (db.select(db.bills)).get();
      // 新语义：记 AA 时不生成收入账单，仅有垫付账单且软删除
      expect(all, hasLength(1));
      expect(all.every((b) => b.deletedAt != null), isTrue);
    });

    test('导入取消墓碑（status=3）：接收方份额账单作废', () async {
      await pair();
      final payload = {
        'format': 1,
        'fromUid': 'partner-uid',
        'fromName': '伙伴',
        'exportedAtMs': 1,
        'groups': [
          {
            'id': 'pg1',
            'ownerUid': 'partner-uid',
            'payerUid': 'partner-uid',
            'totalAmount': 2000,
            'dateMs': 10,
            'status': 0,
            'settled': false,
            'createdAtMs': 1,
            'updatedAtMs': 1,
          }
        ],
        'settlements': [],
      };
      final f = File('${pathProvider.tempDir.path}/cancel.aas')
        ..writeAsStringSync(
            await encryptToAasContent(payload, 'share-secret-1'));
      await svc.importSyncFile(f.path);
      final g = (await db.getAllAaGroups()).single;
      // 旧模型遗留的份额账单（挂 aaGroupId）：用于验证墓碑作废逻辑
      await db.upsertBill(
        id: 'bill-share',
        type: 0,
        amount: 1000,
        accountId: kAaCreditAccountId,
        dateMs: 10,
        note: 'AA · 伙伴垫付',
        aaGroupId: g.id,
      );
      expect(await db.watchAllBills().first, hasLength(1));

      // 伙伴「取消 AA / 删除」后重发文件：status=3 且 updatedAtMs 比本机新
      payload['groups'] = [
        {
          'id': 'pg1',
          'ownerUid': 'partner-uid',
          'payerUid': 'partner-uid',
          'totalAmount': 2000,
          'dateMs': 10,
          'status': 3,
          'statusNote': '已取消AA',
          'settled': false,
          'createdAtMs': 1,
          'updatedAtMs': DateTime.now().millisecondsSinceEpoch + 1000,
        }
      ];
      f.writeAsStringSync(await encryptToAasContent(payload, 'share-secret-1'));
      await svc.importSyncFile(f.path);

      final bills = await (db.select(db.bills)).get();
      expect(bills, hasLength(1));
      expect(bills.single.deletedAt, isNotNull); // 我的份额账单已作废
      expect((await db.getAaGroup('pg1'))!.status, 3);
    });

    test('normalizeAaShareAmounts：历史奇数份额重算为向下取整', () async {
      await pair();
      await db.upsertAaGroup(AaGroupsCompanion.insert(
        id: 'g1',
        ownerUid: (await db.getMeta('myUid'))!,
        payerUid: (await db.getMeta('myUid'))!,
        totalAmount: 10001,
        dateMs: 10,
        createdAtMs: 1,
        updatedAtMs: 1,
      ));
      // 旧口径留下的挂账应收 5001（应为 5000）；全额账单 10001 保持不动
      await db.upsertBill(
          id: 'bill-full',
          type: 0,
          amount: 10001,
          accountId: 'acc_cash',
          dateMs: 10,
          aaGroupId: 'g1');
      await db.upsertBill(
          id: 'bill-receivable',
          type: 1,
          amount: 5001,
          accountId: kAaCreditAccountId,
          dateMs: 10,
          aaGroupId: 'g1');

      await db.normalizeAaShareAmounts();

      final bills = await (db.select(db.bills)).get();
      expect(bills.firstWhere((b) => b.id == 'bill-full').amount, 10001);
      expect(bills.firstWhere((b) => b.id == 'bill-receivable').amount, 5000);
    });
  });
}

/// 从路径取文件名（不引入 path 包依赖）
String basenameLike(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i < 0 ? path : path.substring(i + 1);
}
