import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/accounts_page.dart';
import 'package:aa_expense_splitter/pages/bill_detail_page.dart';
import 'package:aa_expense_splitter/pages/bills_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../helpers/test_support.dart';

Future<void> _saveEditedBill(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('保存'));
  });
  for (
    var i = 0;
    i < 50 && find.byType(EditBillPage).evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(EditBillPage), findsNothing);
  await settleProviders(tester);
}

void main() {
  int ms(int day, [int hour = 12]) => DateTime(
    DateTime.now().year,
    DateTime.now().month,
    day,
    hour,
  ).millisecondsSinceEpoch;

  testWidgets('空月显示引导空态', (tester) async {
    final db = await pumpPage(tester, const BillsPage());
    expect(find.text('本月还没有账单'), findsOneWidget);
    expect(find.text('点击下方 + 记一笔'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('加载中显示进度圈（流未发射）', (tester) async {
    // loading 态的转圈动画使 pumpAndSettle 永不结束，这里手动泵一帧；
    // 且完全不接触数据库（避免 fake-async 与 drift 关闭流程互锁）
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monthBillsProvider.overrideWith((ref) => const Stream.empty()),
          accountsProvider.overrideWith(
            (ref) => Stream.value(const <Account>[]),
          ),
          categoriesProvider.overrideWith(
            (ref) => Stream.value(const <Category>[]),
          ),
        ],
        child: localizedApp(const BillsPage()),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  });

  testWidgets('流错误显示读取失败', (tester) async {
    final db = await pumpPage(
      tester,
      const BillsPage(),
      overrides: [
        monthBillsProvider.overrideWith((ref) => Stream.error('boom')),
      ],
    );
    expect(find.textContaining('读取失败：boom'), findsOneWidget);
    await disposePage(tester, db);
  });

  testWidgets('按日分组展示各类账单与月摘要', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    Future<void> add(Bill b) => db.upsertBill(
      id: b.id,
      type: b.type,
      amount: b.amount,
      categoryId: b.categoryId,
      accountId: b.accountId,
      toAccountId: b.toAccountId,
      dateMs: b.dateMs,
      note: b.note,
      aaGroupId: b.aaGroupId,
    );
    await add(
      mkBill(
        'e1',
        type: 0,
        amount: 8800,
        categoryId: 'cat_food',
        accountId: 'acc_cash',
        dateMs: ms(3),
      ),
    );
    await add(
      mkBill(
        'e2',
        type: 0,
        amount: 1200,
        categoryId: 'cat_transport',
        accountId: 'acc_wechat',
        dateMs: ms(4, 9),
        note: '地铁',
      ),
    );
    await add(
      mkBill(
        'i1',
        type: 1,
        amount: 50000,
        categoryId: 'inc_salary',
        accountId: 'acc_bank',
        dateMs: ms(4, 18),
      ),
    );
    await add(
      mkBill(
        't1',
        type: 2,
        amount: 30000,
        accountId: 'acc_bank',
        toAccountId: 'acc_wechat',
        dateMs: ms(5),
      ),
    );

    await pumpPage(tester, const BillsPage(), db: db);

    // 月摘要：收入 500.00 / 支出 100.00 / 结余 +400.00
    // （+500.00 同时出现在摘要与收入行两处）
    expect(find.text('+500.00'), findsNWidgets(2));
    expect(find.text('-88.00'), findsOneWidget); // 支出行金额
    expect(find.text('+400.00'), findsOneWidget);

    // 支出行：无备注时标题为分类名；有备注为备注
    expect(find.text('餐饮'), findsOneWidget);
    expect(find.text('地铁'), findsOneWidget);
    // 转账行
    expect(find.text('转账'), findsOneWidget);
    expect(find.text('银行卡 → 微信'), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('AA 往来收入不计入月摘要', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'aa',
      type: 1,
      amount: 4950,
      categoryId: 'cat_aa_marker',
      accountId: 'acc_cash',
      dateMs: ms(2),
    );

    await pumpPage(tester, const BillsPage(), db: db);

    // 摘要收入列为 0.00（内部挂账被排除），账单行本身仍显示 +49.50
    expect(find.text('+49.50'), findsOneWidget);
    expect(find.text('0.00'), findsWidgets);

    await disposePage(tester, db);
  });

  testWidgets('轻滑删除、撤销恢复', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'e1',
      type: 0,
      amount: 8800,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: ms(3),
    );

    await pumpPage(tester, const BillsPage(), db: db);
    // tile 标题唯一；金额在摘要与行内出现两次
    expect(find.text('餐饮'), findsOneWidget);

    // 左滑露出删除按钮
    await tester.drag(find.text('餐饮'), const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip('删除'), findsOneWidget);

    // 点击删除 → 软删除 + SnackBar 撤销
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('已删除 1 笔账单'), findsOneWidget);
    expect(find.text('餐饮'), findsNothing);

    final bills1 = await db
        .customSelect('SELECT COUNT(*) c FROM bills WHERE deleted_at IS NULL')
        .getSingle();
    expect(bills1.read<int>('c'), 0);

    // 撤销恢复
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('餐饮'), findsOneWidget);
    final bills2 = await db
        .customSelect(
          'SELECT deleted_at d FROM bills WHERE id = ?',
          variables: [Variable.withString('e1')],
        )
        .getSingle();
    expect(bills2.data['d'], isNull);

    await disposePage(tester, db);
  });

  testWidgets('滑开状态点击账单本体先收起按钮', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'e1',
      type: 0,
      amount: 8800,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: ms(3),
    );

    await pumpPage(tester, const BillsPage(), db: db);

    // 删除按钮是 Stack 常驻底层，滑动状态用 tile 的平移量断言
    double tileDx() => tester
        .widget<Transform>(
          find
              .ancestor(of: find.text('餐饮'), matching: find.byType(Transform))
              .first,
        )
        .transform
        .getTranslation()
        .x;
    expect(tileDx(), 0);

    await tester.drag(find.text('餐饮'), const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(tileDx(), -76); // 滑开到位

    // 点击账单本体 → 收起（不平移），不进详情页或编辑页
    await tester.tap(find.text('餐饮'));
    await tester.pumpAndSettle();
    expect(tileDx(), 0);
    expect(find.byType(BillDetailPage), findsNothing);
    expect(find.byType(EditBillPage), findsNothing);

    // 再次点击（未滑开）→ 进入只读详情，按「修改」才进入编辑页
    await tester.tap(find.text('餐饮'));
    await tester.pumpAndSettle();
    expect(find.byType(BillDetailPage), findsOneWidget);
    expect(find.byType(EditBillPage), findsNothing);

    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(find.byType(EditBillPage), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('AA 账单行无滑动删除层', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'aa1',
      type: 0,
      amount: 5001,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: ms(3),
      aaGroupId: 'g1',
    );

    await pumpPage(tester, const BillsPage(), db: db);

    // AA 支出账单按设计图显示为「AA平分：分类/备注」
    expect(find.text('AA平分：餐饮'), findsOneWidget);
    await tester.drag(find.text('AA平分：餐饮'), const Offset(-100, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip('删除'), findsNothing);

    await disposePage(tester, db);
  });

  testWidgets('账单连续两次编辑保留最新金额与备注', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'refresh_bill',
      type: 0,
      amount: 1000,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: ms(3),
      note: '修改前的账单',
    );
    await pumpPage(tester, const BillsPage(), db: db);

    await tester.tap(find.text('修改前的账单'));
    await settleProviders(tester);
    await tester.tap(find.text('修改'));
    await settleProviders(tester);
    await tester.longPress(find.text('⌫'));
    await tester.tap(find.text('2'));
    await tester.tap(find.text('0'));
    await tester.enterText(find.byType(TextField), '第一次修改');
    tester.testTextInput.hide();
    await _saveEditedBill(tester);

    expect(find.byType(BillDetailPage), findsOneWidget);
    expect(find.text('-¥ 20.00'), findsOneWidget);
    expect(find.text('第一次修改'), findsOneWidget);
    expect(find.text('修改前的账单'), findsNothing);

    await tester.tap(find.text('修改'));
    await settleProviders(tester);
    final noteField = tester.widget<TextField>(find.byType(TextField));
    expect(noteField.controller!.text, '第一次修改');
    // 第二次只改备注；金额必须沿用第一次保存的 20 元。
    await tester.enterText(find.byType(TextField), '第二次修改');
    tester.testTextInput.hide();
    await _saveEditedBill(tester);

    expect(find.text('-¥ 20.00'), findsOneWidget);
    expect(find.text('第二次修改'), findsOneWidget);
    final saved = (await db.getAllBills()).single;
    expect(saved.id, 'refresh_bill');
    expect(saved.amount, 2000);
    expect(saved.note, '第二次修改');
    expect(saved.categoryId, 'cat_food');
    expect(saved.accountId, 'acc_cash');
    await disposePage(tester, db);
  });

  testWidgets('编辑页软删除账单后详情不再提供修改入口', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'deleted_detail_bill',
      type: 0,
      amount: 1000,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: ms(3),
      note: '详情删除保护',
    );
    await pumpPage(tester, const BillsPage(), db: db);

    await tester.tap(find.text('详情删除保护'));
    await settleProviders(tester);
    await tester.tap(find.text('修改'));
    await settleProviders(tester);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await settleProviders(tester);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
    });
    for (
      var i = 0;
      i < 50 && find.byType(EditBillPage).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settleProviders(tester);

    expect(find.byType(EditBillPage), findsNothing);
    expect(find.text('修改'), findsNothing);
    expect(find.text('详情删除保护'), findsNothing);
    expect(await db.getAllBills(), isEmpty);
    final deleted = await (db.select(
      db.bills,
    )..where((b) => b.id.equals('deleted_detail_bill'))).getSingle();
    expect(deleted.deletedAt, isNotNull);
    await disposePage(tester, db);
  });

  testWidgets('右上角账本按钮进入账本页', (tester) async {
    final db = await pumpPage(tester, const BillsPage());

    await tester.tap(find.byTooltip('账本'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountsPage), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('月份切换后展示另一月空态', (tester) async {
    final db = TestAppDatabase();
    await db.getAllAccounts();
    await db.upsertBill(
      id: 'e1',
      type: 0,
      amount: 8800,
      categoryId: 'cat_food',
      accountId: 'acc_cash',
      dateMs: ms(3),
    );

    await pumpPage(tester, const BillsPage(), db: db);
    expect(find.text('餐饮'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('本月还没有账单'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('餐饮'), findsOneWidget);

    await disposePage(tester, db);
  });
}
