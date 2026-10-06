import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/accounts_page.dart';
import 'package:aa_expense_splitter/pages/mine_page.dart';

import '../helpers/test_support.dart';

void main() {
  testWidgets('页面渲染：入口、M2 角标与隐私说明', (tester) async {
    final db = await pumpPage(tester, const MinePage());

    expect(find.text('我的'), findsOneWidget);
    expect(find.text('账户与资产'), findsOneWidget);
    expect(find.text('预算'), findsOneWidget);
    expect(find.text('数据导出'), findsOneWidget);
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('隐私说明'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    // 三个 M2 占位角标
    expect(find.text('M2'), findsNWidgets(3));

    await disposePage(tester, db);
  });

  testWidgets('账户与资产跳转到账本页', (tester) async {
    final db = await pumpPage(tester, const MinePage());

    await tester.tap(find.text('账户与资产'));
    await tester.pumpAndSettle();

    expect(find.byType(AccountsPage), findsOneWidget);

    await disposePage(tester, db);
  });

  testWidgets('预算/数据导出/回收站点击提示后续版本', (tester) async {
    final db = await pumpPage(tester, const MinePage());

    for (final label in ['预算', '数据导出', '回收站']) {
      await tester.tap(find.text(label).last);
      await tester.pump(); // SnackBar 弹出
      expect(find.textContaining('在后续版本提供'), findsOneWidget);
      // 等 SnackBar（默认 4s）完全退出再点下一个
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }

    await disposePage(tester, db);
  });
}
