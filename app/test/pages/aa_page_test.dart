

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart'
    as fpi;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart'
    as spi;

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/pages/aa_page.dart';
import 'package:aa_expense_splitter/sync/aa_crypto.dart';

import '../helpers/test_support.dart';

/// 有界泵帧：替代 pumpAndSettle，避免某个动画不停时把整组测试挂死 10 分钟
Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(seconds: 3));
}

/// 包装 testWidgets，强制 45 秒超时（不允许任何用例挂 10 分钟）
void fastTest(String description, WidgetTesterCallback callback) {
  testWidgets(description, callback,
      timeout: const Timeout(Duration(seconds: 45)));
}

void main() {
  late FakePathProvider pathProvider;
  late FakeSharePlatform share;

  setUp(() {
    pathProvider = FakePathProvider();
    PathProviderPlatform.instance = pathProvider;
    share = FakeSharePlatform();
    spi.SharePlatform.instance = share;
  });

  tearDown(() {
    pathProvider.cleanup();
  });

  /// 配对并写入指定净额场景的分摊组
  Future<TestAppDatabase> pairedDb({
    String myName = '我',
    String partnerName = '伙伴',
    List<AaGroupsCompanion> groups = const [],
    List<SettlementsCompanion> settlements = const [],
    bool keepRealAccounts = true,
  }) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.setMeta('myName', myName);
    await db.setMeta('partnerName', partnerName);
    await db.setMeta('pairSecret', 'secret-1');
    final myUid = 'uid-me';
    await db.setMeta('myUid', myUid);
    await db.upsertAccount(
        id: kAaCreditAccountId,
        name: 'AA挂账',
        emoji: '🤝',
        type: 4,
        initBalance: 0,
        includeNetWorth: false,
        sort: 99);
    if (!keepRealAccounts) {
      for (final a in await db.getAllAccounts()) {
        if (a.id != kAaCreditAccountId) await db.deleteAccount(a.id);
      }
    }
    for (final g in groups) {
      await db.upsertAaGroup(g);
    }
    for (final s in settlements) {
      await db.upsertSettlement(s);
    }
    return db;
  }

  group('配对表单（未配对）', () {
    fastTest('渲染表单', (tester) async {
      final db = await pumpPage(tester, const AaPage());
      // 标题「建立配对」+ 提交按钮「建立配对」
      expect(find.text('建立配对'), findsNWidgets(2));
      expect(find.text('🤝'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('昵称为空提示', (tester) async {
      final db = await pumpPage(tester, const AaPage());
      await tester.enterText(find.widgetWithText(TextField, '我的昵称'), '');
      await tester.enterText(find.widgetWithText(TextField, '伙伴昵称'), '');
      await tester.tap(find.text('建立配对').last);
      await tester.pump();
      expect(find.text('请填写双方昵称'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('口令过短提示', (tester) async {
      final db = await pumpPage(tester, const AaPage());
      await tester.enterText(find.widgetWithText(TextField, '我的昵称'), '我');
      await tester.enterText(find.widgetWithText(TextField, '伙伴昵称'), '伙伴');
      await tester.enterText(
          find.widgetWithText(TextField, '配对口令（至少 6 位，双方相同）'), '123');
      await tester.tap(find.text('建立配对').last);
      await tester.pump();
      expect(find.text('配对口令至少 6 位'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('两次口令不一致提示', (tester) async {
      final db = await pumpPage(tester, const AaPage());
      await tester.enterText(find.widgetWithText(TextField, '我的昵称'), '我');
      await tester.enterText(find.widgetWithText(TextField, '伙伴昵称'), '伙伴');
      await tester.enterText(
          find.widgetWithText(TextField, '配对口令（至少 6 位，双方相同）'), '123456');
      await tester.enterText(find.widgetWithText(TextField, '确认口令'), '654321');
      await tester.tap(find.text('建立配对').last);
      await tester.pump();
      expect(find.text('两次口令不一致'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('口令可见性切换按钮', (tester) async {
      final db = await pumpPage(tester, const AaPage());
      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump();
      expect(find.byIcon(Icons.visibility), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('正确填写后配对成功进入仪表盘', (tester) async {
      final db = await pumpPage(tester, const AaPage());
      await tester.enterText(find.widgetWithText(TextField, '我的昵称'), '我');
      await tester.enterText(find.widgetWithText(TextField, '伙伴昵称'), '伙伴');
      await tester.enterText(
          find.widgetWithText(TextField, '配对口令（至少 6 位，双方相同）'), '123456');
      await tester.enterText(find.widgetWithText(TextField, '确认口令'), '123456');
      await tester.tap(find.text('建立配对').last);
      await tester.pumpAndSettle();

      expect(find.text('配对完成，已创建「AA挂账」账户'), findsOneWidget);
      expect(await db.getMeta('pairSecret'), '123456');
      // 仪表盘出现
      expect(find.text('已两清 🤝'), findsOneWidget);
      await disposePage(tester, db);
    });
  });

  group('已配对仪表盘', () {
    fastTest('净额为零显示已两清', (tester) async {
      final db = await pairedDb();
      await pumpPage(tester, const AaPage(), db: db);
      expect(find.text('已两清 🤝'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('我垫付多笔 → 伙伴应转给我并显示结算按钮', (tester) async {
      final db = await pairedDb(groups: [
        AaGroupsCompanion.insert(
            id: 'g1',
            ownerUid: 'uid-me',
            payerUid: 'uid-me',
            totalAmount: 10000,
            dateMs: 10,
            note: const Value('晚饭'),
            categoryName: const Value('餐饮'),
            categoryEmoji: const Value('🍜'),
            createdAtMs: 1,
            updatedAtMs: 1),
      ]);
      await pumpPage(tester, const AaPage(), db: db);
      expect(find.text('伙伴 应转给你'), findsOneWidget);
      // 差额卡与列表尾部各显示一次份额
      expect(find.text('¥ 50.00'), findsNWidgets(2));
      expect(find.text('去结算'), findsOneWidget);
      expect(find.text('我垫付 · 餐饮 · 晚饭'), findsOneWidget);
      expect(find.textContaining('待伙伴确认'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('伙伴垫付 → 我应转给伙伴（红字）', (tester) async {
      final db = await pairedDb(groups: [
        AaGroupsCompanion.insert(
            id: 'g2',
            ownerUid: 'uid-partner',
            payerUid: 'uid-partner',
            totalAmount: 6600,
            dateMs: 10,
            createdAtMs: 1,
            updatedAtMs: 1),
      ]);
      await pumpPage(tester, const AaPage(), db: db);
      expect(find.text('你应转给 伙伴'), findsOneWidget);
      // 差额卡与应付分区行尾各显示一次份额
      expect(find.text('¥ 33.00'), findsNWidgets(2));
      // 无分类名时行标题为「伙伴垫付 · 」
      expect(find.text('伙伴垫付 · '), findsOneWidget);
      // 「伙伴垫付」还出现在应付分区标题「应付账单（伙伴垫付 · 未结算）」里
      expect(find.textContaining('伙伴垫付'), findsNWidgets(2));
      await disposePage(tester, db);
    });

    fastTest('结算对话框：无真实账户时提示', (tester) async {
      final db = await pairedDb(groups: [
        AaGroupsCompanion.insert(
            id: 'g1',
            ownerUid: 'uid-me',
            payerUid: 'uid-me',
            totalAmount: 10000,
            dateMs: 10,
            createdAtMs: 1,
            updatedAtMs: 1),
      ], keepRealAccounts: false);
      await pumpPage(tester, const AaPage(), db: db);

      await tester.tap(find.text('去结算'));
      await tester.pumpAndSettle();
      expect(find.text('请先在「账本」中创建真实账户'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('结算：确认后逐条生成收入账单（收款方向）', (tester) async {
      final db = await pairedDb(groups: [
        AaGroupsCompanion.insert(
            id: 'g1',
            ownerUid: 'uid-me',
            payerUid: 'uid-me',
            totalAmount: 10000,
            dateMs: 10,
            createdAtMs: 1,
            updatedAtMs: 1),
      ]);
      await db.setMeta('partnerUid', 'uid-partner');
      await pumpPage(tester, const AaPage(), db: db);

      await tester.tap(find.text('去结算'));
      await pumpFrames(tester);
      expect(find.text('AA 结算'), findsOneWidget);
      expect(find.text('伙伴 转给你 ¥ 50.00'), findsOneWidget);
      expect(find.text('确认结算'), findsOneWidget);
      expect(find.text('收入到账户'), findsOneWidget);
      // 结算执行逻辑由 aa_sync_service_test 覆盖，此处只验 UI
      await tester.tap(find.text('取消'));
      await pumpFrames(tester);
      await disposePage(tester, db);
    });


    fastTest('结算：取消不产生数据', (tester) async {
      final db = await pairedDb(groups: [
        AaGroupsCompanion.insert(
            id: 'g1',
            ownerUid: 'uid-me',
            payerUid: 'uid-me',
            totalAmount: 10000,
            dateMs: 10,
            createdAtMs: 1,
            updatedAtMs: 1),
      ]);
      await db.setMeta('partnerUid', 'uid-partner');
      await pumpPage(tester, const AaPage(), db: db);

      await tester.tap(find.text('去结算'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();

      expect(await db.getAllSettlements(), isEmpty);
      await disposePage(tester, db);
    });

    fastTest('导出：生成文件并调用分享', (tester) async {
      final db = await pairedDb();
      await pumpPage(tester, const AaPage(), db: db);

      await tester.tap(find.text('导出并发送'));
      // 导出含 PBKDF2 加密（真实耗时数百毫秒），轮询等待分享方式弹层出现
      for (var i = 0;
          i < 30 && find.textContaining('系统分享').evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      await pumpFrames(tester);
      // 导出成功后弹出分享方式选择
      await tester.tap(find.textContaining('系统分享'));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await pumpFrames(tester);

      expect(share.lastParams, isNotNull);
      expect(share.lastParams!.files!.single.path, endsWith('.aas'));
      expect(await db.getMeta('lastExportAt'), isNotNull);
      await disposePage(tester, db);
    });

    fastTest('导入：取消选择无提示', (tester) async {
      fpi.FilePickerPlatform.instance = FakeFilePicker(null);
      final db = await pairedDb();
      await pumpPage(tester, const AaPage(), db: db);

      await tester.tap(find.text('导入伙伴文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('导入成功'), findsNothing);
      await disposePage(tester, db);
    });

    fastTest('导入：成功合并伙伴文件', (tester) async {
      // 构造伙伴导出的 .aas
      final payload = <String, Object?>{
        'format': 1,
        'fromUid': 'uid-partner',
        'fromName': '伙伴',
        'exportedAtMs': 1,
        'groups': [
          {
            'id': 'pg1',
            'ownerUid': 'uid-partner',
            'payerUid': 'uid-partner',
            'totalAmount': 2000,
            'dateMs': 10,
            'note': '奶茶',
            'categoryName': '餐饮',
            'categoryEmoji': '🧋',
            'status': 0,
            'statusByUid': null,
            'statusAtMs': null,
            'settled': false,
            'settlementId': null,
            'createdAtMs': 1,
            'updatedAtMs': 1,
          }
        ],
        'settlements': [],
      };
      final f = File('${pathProvider.tempDir.path}/partner.aas');
      await tester.runAsync(() async {
        f.writeAsStringSync(await encryptToAasContent(payload, 'secret-1'));
      });
      final db = await pairedDb();
      await pumpPage(tester, const AaPage(), db: db);

      await tester.tap(find.text('导入伙伴文件'));
      await tester.pump(); // 先派发点击，让导入链进入真实异步
      // 文件读取/口令解密是真实异步，回真实事件循环跑完（testWidgets 默认假异步）
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 800)));
      await pumpFrames(tester);

      expect(find.textContaining('导入成功'), findsOneWidget);
      expect(await db.getMeta('partnerUid'), 'uid-partner');
      // 待入账卡出现（伙伴发起 status=0），导入后自动弹出份额入账面板
      expect(find.text('待你入账（1）'), findsOneWidget);
      expect(find.textContaining('待你入账'), findsOneWidget);

      // 关闭自动弹出的入账面板，让 _import 的未 await 链正常收尾
      await tester.tap(find.text('入账并确认'));
      await pumpFrames(tester);
      await disposePage(tester, db);
    });

    fastTest('导入：口令不一致提示失败', (tester) async {
      final f = File('${pathProvider.tempDir.path}/bad.aas');
      await tester.runAsync(() async {
        f.writeAsStringSync(await encryptToAasContent({'fromUid': 'x'}, '别的口令'));
      });
      final db = await pairedDb();
      await pumpPage(tester, const AaPage(), db: db);

      await tester.tap(find.text('导入伙伴文件'));
      await tester.pump(); // 先派发点击，让导入链进入真实异步
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 800)));
      await pumpFrames(tester);

      expect(find.textContaining('导入失败'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('待入账：退回（带理由）后不再待入账', (tester) async {
      final db = await pairedDb(groups: [
        AaGroupsCompanion.insert(
            id: 'pg1',
            ownerUid: 'uid-partner',
            payerUid: 'uid-partner',
            totalAmount: 2000,
            dateMs: 10,
            categoryName: const Value('餐饮'),
            categoryEmoji: const Value('🍜'),
            createdAtMs: 1,
            updatedAtMs: 1),
      ]);
      await pumpPage(tester, const AaPage(), db: db);

      expect(find.text('待你入账（1）'), findsOneWidget);

      // 退回 → 先弹「退回理由」框（可留空）
      await tester.tap(find.text('退回'));
      await tester.pumpAndSettle();
      expect(find.text('退回 AA 账单'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '这笔应该按 60/40 分');
      await tester.tap(find.widgetWithText(FilledButton, '退回'));
      await tester.pumpAndSettle();

      expect(find.text('已退回，等待伙伴处理'), findsOneWidget);
      final g = (await db.getAaGroup('pg1'))!;
      expect(g.status, 2);
      expect(g.statusNote, '这笔应该按 60/40 分');
      expect(find.text('待你入账（1）'), findsNothing); // 不再待入账

      await disposePage(tester, db);
    });

    fastTest('待入账：入账并确认 status=1', (tester) async {
      final db = await pairedDb(groups: [
        AaGroupsCompanion.insert(
            id: 'pg1',
            ownerUid: 'uid-partner',
            payerUid: 'uid-partner',
            totalAmount: 2000,
            dateMs: 10,
            categoryName: const Value('餐饮'),
            categoryEmoji: const Value('🍜'),
            createdAtMs: 1,
            updatedAtMs: 1),
      ]);
      await pumpPage(tester, const AaPage(), db: db);

      // 点待入账条目 → 打开份额入账面板
      await tester.tap(find.textContaining('总额 ¥ 20.00'));
      await pumpFrames(tester);
      expect(find.textContaining('待你入账'), findsOneWidget);
      await tester.tap(find.text('入账并确认'));
      await pumpFrames(tester);

      expect((await db.getAaGroup('pg1'))!.status, 1);
      // 入账不生成明细账单（图 2），只在 AA 页作为应付跟踪
      expect(await db.watchAllBills().first, isEmpty);
      expect(find.textContaining('已入账'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('待你处理：被退回的 AA 账单显示理由与三个处理入口（不计差额）',
        (tester) async {
      final db = await pairedDb(groups: [
        AaGroupsCompanion.insert(
            id: 'pg1',
            ownerUid: 'uid-me',
            payerUid: 'uid-me',
            totalAmount: 2000,
            dateMs: 10,
            categoryName: const Value('餐饮'),
            categoryEmoji: const Value('🍜'),
            status: const Value(2),
            statusNote: const Value('这笔应该按 60/40 分'),
            createdAtMs: 1,
            updatedAtMs: 1),
      ]);
      await pumpPage(tester, const AaPage(), db: db);

      expect(find.text('待你处理（1）'), findsOneWidget);
      expect(find.text('退回理由：这笔应该按 60/40 分'), findsOneWidget);
      expect(find.text('改金额重发'), findsOneWidget);
      expect(find.text('取消 AA'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      // 挂起中的账单不计入差额
      expect(find.text('已两清 🤝'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('AA 账单列表：空态显示三分区', (tester) async {
      final db = await pairedDb();
      await pumpPage(tester, const AaPage(), db: db);
      // 三分区（应收/应付/已同步）标题 + 各自空态
      expect(find.textContaining('待你入账'), findsOneWidget);
      expect(find.textContaining('应收账单（我垫付 · 未结算）'), findsOneWidget);
      expect(find.textContaining('应付账单（伙伴垫付 · 未结算）'), findsOneWidget);
      expect(find.textContaining('已同步（完成）'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('AA 账单列表：已结算/已拒绝/待我入账状态（三分区）', (tester) async {
      final db = await pairedDb(groups: [
        // 我拥有待伙伴确认
        AaGroupsCompanion.insert(
            id: 'a',
            ownerUid: 'uid-me',
            payerUid: 'uid-me',
            totalAmount: 100,
            dateMs: 10,
            createdAtMs: 1,
            updatedAtMs: 1),
        // 伙伴拥有待我入账（ownerUid != myUid, status 0）
        AaGroupsCompanion.insert(
            id: 'b',
            ownerUid: 'uid-partner',
            payerUid: 'uid-me',
            totalAmount: 200,
            dateMs: 11,
            createdAtMs: 1,
            updatedAtMs: 1),
        // 伙伴拥有已确认（非 owner 视角 = 已入账）
        AaGroupsCompanion.insert(
            id: 'c',
            ownerUid: 'uid-partner',
            payerUid: 'uid-partner',
            totalAmount: 300,
            dateMs: 12,
            status: const Value(1),
            createdAtMs: 1,
            updatedAtMs: 1),
        // 已退回（owner 视角 = 待修改）
        AaGroupsCompanion.insert(
            id: 'd',
            ownerUid: 'uid-me',
            payerUid: 'uid-me',
            totalAmount: 400,
            dateMs: 13,
            status: const Value(2),
            createdAtMs: 1,
            updatedAtMs: 1),
        // 已结算
        AaGroupsCompanion.insert(
            id: 'e',
            ownerUid: 'uid-me',
            payerUid: 'uid-partner',
            totalAmount: 500,
            dateMs: 14,
            settled: const Value(true),
            createdAtMs: 1,
            updatedAtMs: 1),
      ]);
      await pumpPage(tester, const AaPage(), db: db);

      expect(find.textContaining('待你入账'), findsOneWidget);
      expect(find.textContaining('待伙伴确认'), findsOneWidget);
      expect(find.textContaining('待我入账'), findsOneWidget);
      expect(find.textContaining('已入账'), findsOneWidget);
      expect(find.textContaining('待修改（已拒绝）'), findsOneWidget);
      expect(find.textContaining('已结算'), findsOneWidget);
      await disposePage(tester, db);
    });

    fastTest('解除配对：取消与确认', (tester) async {
      final db = await pairedDb();
      await pumpPage(tester, const AaPage(), db: db);

      await tester.tap(find.text('解除配对'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(await db.getMeta('pairSecret'), isNotNull);

      await tester.tap(find.text('解除配对'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('解除'));
      await tester.pumpAndSettle();
      expect(find.text('已解除配对'), findsOneWidget);
      expect(await db.getMeta('pairSecret'), isNull);
      // 回到配对表单（标题与提交按钮都叫「建立配对」）
      expect(find.text('建立配对'), findsNWidgets(2));

      await disposePage(tester, db);
    });
  });
}
