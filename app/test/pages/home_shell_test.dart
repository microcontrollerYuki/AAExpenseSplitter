import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/accounts_page.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/pages/home_shell.dart';

import '../helpers/test_support.dart';

void main() {
  testWidgets('主框架渲染四个页签与记一笔按钮', (tester) async {
    final db = await pumpPage(tester, const HomeShell());

    expect(find.byType(HomeShell), findsOneWidget);
    // IndexedStack 中四个页面都常驻
    expect(find.text('明细'), findsOneWidget);
    expect(find.text('图表'), findsOneWidget);
    expect(find.text('AA'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('点击底部页签切换索引（选中态分支）', (tester) async {
    final db = await pumpPage(tester, const HomeShell());

    await tester.tap(find.text('图表'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.pie_chart), findsOneWidget);

    await tester.tap(find.text('AA'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.handshake), findsOneWidget);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person), findsOneWidget);

    // 切回明细
    await tester.tap(find.text('明细'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.receipt_long), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('中央 + 按钮打开记账页', (tester) async {
    final db = await pumpPage(tester, const HomeShell());

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.byType(EditBillPage), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);

    // 关闭记账页返回主框架
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(EditBillPage), findsNothing);

    await disposePage(tester, db);
  });

  testWidgets('我的页入口可跳转账本页（页面栈导航）', (tester) async {
    final db = await pumpPage(tester, const HomeShell());

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('账户与资产'));
    await tester.pumpAndSettle();

    expect(find.byType(AccountsPage), findsOneWidget);
    expect(find.text('总资产（计入净资产的账户）'), findsOneWidget);

    await disposePage(tester, db);
  });
}
