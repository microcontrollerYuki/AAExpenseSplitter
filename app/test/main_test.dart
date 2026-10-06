import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aa_expense_splitter/main.dart' as app;
import 'package:aa_expense_splitter/pages/home_shell.dart';

import 'helpers/test_support.dart';

void main() {
  // main() 的 runApp 需要真实帧调度 + 真实 IO（文件库走后台 isolate），
  // 默认 AutomatedTestWidgetsFlutterBinding 的 fake-async 会卡死，
  // 这里用 LiveTestWidgetsFlutterBinding 做真实启动
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('应用启动冒烟：main() 渲染出主框架与四个页签', (tester) async {
    final fake = FakePathProvider();
    PathProviderPlatform.instance = fake;

    await tester.runAsync(() async {
      app.main();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.text('明细'), findsOneWidget);
    expect(find.text('图表'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);

    fake.cleanup();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
