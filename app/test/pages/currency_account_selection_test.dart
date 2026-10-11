import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/data/presets.dart';
import 'package:aa_expense_splitter/pages/aa_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/utils/account_selection.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../helpers/test_support.dart';

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
  await settleProviders(tester);
}

Finder _chip(String text) => find.widgetWithText(ActionChip, text);

Future<TestAppDatabase> _seed({
  bool keepCny = true,
  bool paired = false,
}) async {
  final db = TestAppDatabase();
  await db.getAllAccounts();
  if (!keepCny) {
    for (final account in await db.getAllAccounts()) {
      await db.deleteAccount(account.id);
    }
  }
  await db.upsertAccount(
    id: 'usd',
    name: '美元微信',
    emoji: '💲',
    type: 3,
    initBalance: 0,
    includeNetWorth: true,
    sort: -100,
    currency: 'USD',
  );
  if (paired) {
    await db.setMeta('myUid', 'me');
    await db.setMeta('myName', '我');
    await db.setMeta('partnerUid', 'partner');
    await db.setMeta('partnerName', '伙伴');
    await db.setMeta('pairSecret', 'secret');
    await db.upsertAccount(
      id: kAaCreditAccountId,
      name: 'AA挂账',
      emoji: '🤝',
      type: 4,
      initBalance: 0,
      includeNetWorth: false,
      sort: 99,
    );
  }
  return db;
}

Future<void> _openEditor(
  WidgetTester tester,
  TestAppDatabase db, {
  Bill? bill,
}) async {
  await pumpPage(
    tester,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => EditBillPage(bill: bill)),
        ),
        child: const Text('开始'),
      ),
    ),
    db: db,
  );
  await _tap(tester, find.text('开始'));
}

Future<void> _enterFive(WidgetTester tester) => _tap(
  tester,
  find.descendant(of: find.byType(NumberPad), matching: find.text('5')),
);

void _expectRealCnyChoices() {
  expect(find.widgetWithText(ListTile, '现金'), findsOneWidget);
  expect(find.widgetWithText(ListTile, '银行卡'), findsOneWidget);
  expect(find.widgetWithText(ListTile, '美元微信'), findsNothing);
  expect(find.widgetWithText(ListTile, 'AA挂账'), findsNothing);
}

Future<void> _seedAaGroup(TestAppDatabase db) => db.upsertAaGroup(
  AaGroupsCompanion.insert(
    id: 'group',
    ownerUid: 'me',
    payerUid: 'me',
    totalAmount: 1001,
    dateMs: 100,
    createdAtMs: 101,
    updatedAtMs: 102,
  ),
);

Future<Map<String, Object?>> _databaseSnapshot(AppDatabase db) async => {
  'accounts': {
    for (final row in await db.select(db.accounts).get()) row.id: row.toJson(),
  },
  'bills': {
    for (final row in await db.select(db.bills).get()) row.id: row.toJson(),
  },
  'categories': {
    for (final row in await db.select(db.categories).get()) row.id: row.toJson(),
  },
  'groups': {
    for (final row in await db.select(db.aaGroups).get()) row.id: row.toJson(),
  },
  'settlements': {
    for (final row in await db.select(db.settlements).get()) row.id: row.toJson(),
  },
  'meta': {
    for (final row in await db.select(db.metaEntries).get()) row.key: row.value,
  },
};

void main() {
  for (final type in [0, 1]) {
    testWidgets('CNY ${type == 0 ? '支出' : '收入'}默认跳过首位USD，选择器保留人民币AA挂账用途', (
      tester,
    ) async {
      final db = await _seed(paired: true);
      await _openEditor(tester, db);
      if (type == 1) await _tap(tester, find.text('收入'));
      expect(_chip('💵 现金'), findsOneWidget);
      expect(find.textContaining('美元微信'), findsNothing);
      await _tap(tester, _chip('💵 现金'));
      expect(find.widgetWithText(ListTile, '美元微信'), findsNothing);
      expect(find.widgetWithText(ListTile, 'AA挂账'), findsOneWidget);
      await _tap(tester, find.widgetWithText(ListTile, '银行卡'));
      await _enterFive(tester);
      await _tap(tester, find.text('保存'));

      final bill = (await db.getAllBills()).single;
      expect(bill.type, type);
      expect(bill.currency, 'CNY');
      expect(bill.amount, 500);
      expect(bill.accountAmount, 500);
      expect(bill.accountId, 'acc_bank');
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('旧CNY转账的默认双方与两个选择器仅使用真实人民币钱包', (tester) async {
    final db = await _seed(paired: true);
    await _openEditor(tester, db);
    await _tap(tester, find.text('转账'));
    expect(_chip('💵 出 · 现金'), findsOneWidget);
    expect(_chip('💚 入 · 微信'), findsOneWidget);
    await _tap(tester, _chip('💵 出 · 现金'));
    _expectRealCnyChoices();
    await _tap(tester, find.widgetWithText(ListTile, '现金'));
    await _tap(tester, _chip('💚 入 · 微信'));
    _expectRealCnyChoices();
    await _tap(tester, find.widgetWithText(ListTile, '银行卡'));
    await _enterFive(tester);
    await _tap(tester, find.text('保存'));

    final bill = (await db.getAllBills()).single;
    expect(bill.type, 2);
    expect(bill.currency, 'CNY');
    expect(bill.accountId, 'acc_cash');
    expect(bill.toAccountId, 'acc_bank');
    expect(bill.amount, 500);
    expect(bill.accountAmount, 500);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final type in [0, 1, 2]) {
    testWidgets('仅有USD时旧CNY类型$type展示账户空态并拒绝保存', (tester) async {
      final db = await _seed(keepCny: false);
      await _openEditor(tester, db);
      if (type != 0) await _tap(tester, find.text(type == 1 ? '收入' : '转账'));
      await _tap(tester, _chip(type == 2 ? '💳 出 · 选择' : '💳 选择账户'));
      expect(find.text(noCnyAccountMessage), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      Navigator.of(tester.element(find.text('选择账户'))).pop();
      await settleProviders(tester);
      await _enterFive(tester);
      await _tap(tester, find.text('保存'));

      expect(find.text(noCnyAccountMessage), findsOneWidget);
      expect(find.byType(EditBillPage), findsOneWidget);
      expect(await db.getAllBills(), isEmpty);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('仅一个真实CNY加USD时，转账不会把外币当作默认转入账户', (tester) async {
    final db = await _seed(paired: true);
    for (final account in await db.getAllAccounts()) {
      if (account.id != 'usd' &&
          account.id != 'acc_cash' &&
          account.id != kAaCreditAccountId) {
        await db.deleteAccount(account.id);
      }
    }
    await _openEditor(tester, db);
    await _tap(tester, find.text('转账'));
    expect(_chip('💵 出 · 现金'), findsOneWidget);
    expect(_chip('💳 入 · 选择'), findsOneWidget);
    await _enterFive(tester);
    await _tap(tester, find.text('保存'));

    expect(find.text('转账需至少两个不同的人民币账户'), findsOneWidget);
    expect(await db.getAllBills(), isEmpty);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('已有CNY账单编辑可换真实人民币账户，USD不出现在列表', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'old',
      type: 0,
      amount: 1234,
      accountId: 'acc_cash',
      dateMs: 100,
      note: '原账',
    );
    final before = (await db.getAllBills()).single;
    await _openEditor(tester, db, bill: before);
    await _tap(tester, _chip('💵 现金'));
    expect(find.widgetWithText(ListTile, '美元微信'), findsNothing);
    await _tap(tester, find.widgetWithText(ListTile, '微信'));
    await tester.enterText(find.byType(TextField), '保留人民币金额');
    tester.testTextInput.hide();
    await _tap(tester, find.text('保存'));

    final after = (await db.getAllBills()).single;
    expect(after.accountId, 'acc_wechat');
    expect(after.currency, 'CNY');
    expect(after.amount, before.amount);
    expect(after.accountAmount, before.accountAmount);
    expect(after.note, '保留人民币金额');
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final change in ['删除', '改为USD']) {
    testWidgets('已选钱包$change后保存不能静默换绑，主动重选CNY才可保存', (tester) async {
      final db = await _seed();
      await _openEditor(tester, db);
      await _tap(tester, _chip('💵 现金'));
      await _tap(tester, find.widgetWithText(ListTile, '银行卡'));
      expect(_chip('🏦 银行卡'), findsOneWidget);
      await tester.runAsync(() async {
        if (change == '删除') {
          await db.deleteAccount('acc_bank');
        } else {
          final account = (await db.getAccount('acc_bank'))!;
          await db.upsertAccount(
            id: account.id,
            name: account.name,
            emoji: account.emoji,
            type: account.type,
            initBalance: account.initBalance,
            includeNetWorth: account.includeNetWorth,
            sort: account.sort,
            currency: 'USD',
          );
        }
      });
      await settleProviders(tester);
      await _enterFive(tester);
      await _tap(tester, find.text('保存'));

      expect(await db.getAllBills(), isEmpty);
      expect(find.byType(EditBillPage), findsOneWidget);
      expect(find.text('所选账户已变化，请重新选择人民币账户'), findsOneWidget);
      await _tap(tester, _chip('💳 选择账户'));
      expect(find.widgetWithText(ListTile, '美元微信'), findsNothing);
      expect(find.widgetWithText(ListTile, '银行卡'), findsNothing);
      await _tap(tester, find.widgetWithText(ListTile, '微信'));
      await _tap(tester, find.text('保存'));

      final bill = (await db.getAllBills()).single;
      expect(bill.accountId, 'acc_wechat');
      expect(bill.currency, 'CNY');
      expect(bill.amount, 500);
      expect(bill.accountAmount, 500);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('CNY旧孤立账不静默换绑，重选后仍保留整库并说明历史币种无法确认', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'orphan',
      type: 0,
      amount: 1234,
      accountId: 'acc_cash',
      dateMs: 100,
      note: '保留原始孤立账',
    );
    final before = (await db.getAllBills()).single;
    // 新DAO已阻止引用账户删除；模拟升级前就存在的孤立账数据。
    await db.customStatement('DELETE FROM accounts WHERE id = ?', ['acc_cash']);
    final databaseBefore = await _databaseSnapshot(db);
    await _openEditor(tester, db, bill: before);
    await tester.enterText(find.byType(TextField), '只改备注');
    tester.testTextInput.hide();
    await _tap(tester, find.text('保存'));

    expect((await db.getAllBills()).single, before);
    expect(await _databaseSnapshot(db), databaseBefore);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(find.text('所选账户已变化，请重新选择人民币账户'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await settleProviders(tester);
    await _tap(tester, _chip('💳 选择账户'));
    await _tap(tester, find.widgetWithText(ListTile, '微信'));
    await _tap(tester, find.text('保存'));

    expect(await _databaseSnapshot(db), databaseBefore);
    expect((await db.getAllBills()).single, before);
    expect(find.byType(EditBillPage), findsOneWidget);
    expect(find.text('原账户已不存在，无法确认历史币种，暂不能修改该账单'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final currency in ['USD', 'CNY']) {
    testWidgets('涉及USD账户的$currency原账在旧CNY编辑页只读，双金额和账户不变', (tester) async {
      final db = await _seed();
      await db.upsertBill(
        id: 'foreign',
        type: 0,
        amount: 1000,
        accountId: 'usd',
        currency: currency,
        accountAmount: currency == 'USD' ? 1000 : 140,
        dateMs: 100,
        note: '外币原账',
      );
      final before = (await db.getAllBills()).single;
      await _openEditor(tester, db, bill: before);

      expect(find.text('暂不能编辑'), findsOneWidget);
      expect(find.text('该账单涉及外币，币种记账功能开放后可编辑。现有金额和账户将保留。'), findsOneWidget);
      expect(find.byType(NumberPad), findsNothing);
      expect(find.text('保存'), findsNothing);
      expect(find.byTooltip('图片识别记账'), findsNothing);
      expect((await db.getAllBills()).single, before);
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  testWidgets('结算账单编辑选择器排除USD与AA，只改本机账户和备注', (tester) async {
    final db = await _seed(paired: true);
    await db.upsertBill(
      id: 'settlement-bill',
      type: 1,
      amount: 1234,
      accountId: 'acc_cash',
      dateMs: 100,
      note: '结算原备注',
      settlementId: 'settlement',
    );
    final before = (await db.getAllBills()).single;
    await _openEditor(tester, db, bill: before);
    await _tap(tester, _chip('💵 现金'));
    _expectRealCnyChoices();
    await _tap(tester, find.widgetWithText(ListTile, '微信'));
    await tester.enterText(find.byType(TextField), '本机新备注');
    tester.testTextInput.hide();
    await _tap(tester, find.text('保存'));

    final after = (await db.getAllBills()).single;
    expect(after.accountId, 'acc_wechat');
    expect(after.currency, 'CNY');
    expect(after.amount, 1234);
    expect(after.accountAmount, 1234);
    expect(after.settlementId, 'settlement');
    expect(after.note, '本机新备注');
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('AA结算下拉只列真实CNY，选择后生成正确CNY双金额', (tester) async {
    final db = await _seed(paired: true);
    await _seedAaGroup(db);
    await pumpPage(tester, const AaPage(), db: db);
    await _tap(tester, find.text('去结算'));
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    final ids = dropdown.items!.map((item) => item.value).toList();
    expect(ids, contains('acc_cash'));
    expect(ids, isNot(contains('usd')));
    expect(ids, isNot(contains(kAaCreditAccountId)));
    await _tap(tester, find.byType(DropdownButton<String>));
    await _tap(tester, find.text('💚 微信').last);
    await _tap(tester, find.text('确认结算'));

    final bill = (await db.getAllBills()).single;
    expect(bill.accountId, 'acc_wechat');
    expect(bill.currency, 'CNY');
    expect(bill.amount, 500);
    expect(bill.accountAmount, 500);
    expect((await db.getAaGroup('group'))!.settled, isTrue);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('AA仅有USD和挂账时提示创建人民币账户，不打开结算或核销', (tester) async {
    final db = await _seed(keepCny: false, paired: true);
    await _seedAaGroup(db);
    final before = (await db.getAaGroup('group'))!;
    await pumpPage(tester, const AaPage(), db: db);
    await _tap(tester, find.text('去结算'));

    expect(find.text(noCnyAccountMessage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(await db.getAaGroup('group'), before);
    expect(await db.getAllSettlements(), isEmpty);
    expect(await db.getAllBills(), isEmpty);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final keepCny in [true, false]) {
    testWidgets('OCR猜测与结果面板过滤首位同名USD，人民币账户存在=$keepCny', (tester) async {
      final previousPicker = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = FakeImagePickerPlatform('/synthetic.jpg');
      mockMlKitTextRecognition([
        ['付款成功', '实付金额', '￥12.34', '付款方式', '美元微信', '餐饮测试商户'],
      ]);
      addTearDown(() {
        ImagePickerPlatform.instance = previousPicker;
        clearMlKitMock();
      });
      final db = await _seed(keepCny: keepCny);
      await _openEditor(tester, db);
      await _tap(tester, find.byTooltip('图片识别记账'));
      await _tap(tester, find.text('从相册选择'));
      expect(find.text('图片识别结果'), findsOneWidget);
      if (keepCny) expect(find.text('💚 微信'), findsOneWidget);
      if (!keepCny) expect(find.text(noCnyAccountMessage), findsOneWidget);
      await _tap(tester, find.text('账户'));
      expect(find.widgetWithText(ListTile, '美元微信'), findsNothing);
      if (keepCny) {
        await _tap(tester, find.widgetWithText(ListTile, '银行卡'));
      } else {
        expect(find.byType(ListTile), findsNothing);
        Navigator.of(tester.element(find.text('选择账户'))).pop();
        await settleProviders(tester);
      }
      await _tap(tester, find.text('采用并填入'));
      // 先读完采用提示；SnackBar队列不会用保存错误覆盖尚在展示的提示。
      await tester.pump(const Duration(seconds: 3));
      await settleProviders(tester);
      await _tap(tester, find.text('保存'));

      if (keepCny) {
        final bill = (await db.getAllBills()).single;
        expect(bill.accountId, 'acc_bank');
        expect(bill.currency, 'CNY');
        expect(bill.amount, 1234);
        expect(bill.accountAmount, 1234);
      } else {
        expect(await db.getAllBills(), isEmpty);
        expect(find.text(noCnyAccountMessage), findsOneWidget);
        expect(find.byType(EditBillPage), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
