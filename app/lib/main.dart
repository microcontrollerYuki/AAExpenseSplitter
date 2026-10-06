import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/aa_page.dart';
import 'pages/home_shell.dart';
import 'providers.dart';
import 'sync/aa_sync_service.dart';
import 'theme.dart';

/// 全局 navigator key（「打开方式」导入的弹窗需要跨页面上下文）
final navigatorKey = GlobalKey<NavigatorState>();

/// 全局容器：让 main 里的「打开方式」处理逻辑能读到数据库等服务
final container = ProviderContainer();

const _openFileChannel = MethodChannel('aa_expense/open_file');

void main() {
  runApp(UncontrolledProviderScope(
      container: container, child: const AAApp()));
  _initOpenFile();
}

/// 「打开方式」导入 .aas 同步文件：冷启动拉取 + 运行中推送
Future<void> _initOpenFile() async {
  _openFileChannel.setMethodCallHandler((call) async {
    if (call.method == 'onOpenFile' && call.arguments is String) {
      await _handleOpenFile(call.arguments as String);
    }
  });
  try {
    final initial =
        await _openFileChannel.invokeMethod<String>('getInitialFile');
    if (initial != null && initial.isNotEmpty) {
      // 等首帧渲染完成，navigatorKey 才有可用 context
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await _handleOpenFile(initial);
    }
  } catch (_) {
    // 通道不可用（单元测试环境的 MissingPluginException / 非 Android 平台）忽略
  }
}

Future<void> _handleOpenFile(String path) async {
  if (!path.toLowerCase().endsWith('.aas')) return;
  final context = navigatorKey.currentContext;
  if (context == null) return;
  final db = container.read(databaseProvider);
  final paired = await db.getMeta('pairSecret') != null;
  if (!paired) {
    _showResult('无法导入',
        '尚未配对：请先在「AA」页完成配对（与伙伴使用同一口令），再打开同步文件。');
    return;
  }
  try {
    final msg = await AaSyncService(db).importSyncFile(path);
    await _showResult('导入完成', '$msg\n可到「AA」页查看待确认账单与差额。');
    // 有待入账的伙伴账单时，依次弹出选账户/分类/备注
    await _openPendingAaSheets();
  } catch (e) {
    debugPrint('[AASync] import error: $e');
    _showResult('导入失败', '口令不一致或文件损坏。\n详情：$e');
  }
}

Future<void> _openPendingAaSheets() async {
  final db = container.read(databaseProvider);
  final service = AaSyncService(db);
  final pending = await service.pendingShareGroups();
  if (pending.isEmpty) return;
  final ctx = navigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  final g = pending.first;
  final res = await showModalBottomSheet<String>(
    context: ctx,
    isScrollControlled: true,
    builder: (_) => AaShareSheet(
      group: g,
      service: service,
    ),
  );
  if (res == null) return; // 用户中断，剩余留在 AA 页处理
  await _openPendingAaSheets();
}

Future<void> _showResult(String title, String content) async {
  final context = navigatorKey.currentContext;
  if (context == null) return;
  await showDialog<void>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('好')),
      ],
    ),
  );
}

class AAApp extends StatelessWidget {
  const AAApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AA记账',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: kPrimaryColor,
        scaffoldBackgroundColor: const Color(0xFFF4F6F5),
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      locale: const Locale('zh', 'CN'),
      home: const HomeShell(),
    );
  }
}
