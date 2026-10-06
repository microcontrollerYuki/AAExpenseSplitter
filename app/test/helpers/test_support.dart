// 测试公共设施：内存数据库、假 PathProvider、本地化 MaterialApp 包装。
// 被 @visibleForTesting 之外的业务代码依赖，仅测试目录引用。
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart'
    as fpi;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' as ip;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
        as ipi;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:share_plus/share_plus.dart' as sp;
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart'
    as spi;

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/providers.dart';

/// 内存版 AppDatabase：不落盘、不依赖 path_provider
class TestAppDatabase extends AppDatabase {
  TestAppDatabase() : super(executor: NativeDatabase.memory());
}

/// 用临时目录应答 path_provider（AaSyncService 导出 / _openConnection 用）
class FakePathProvider extends PathProviderPlatform {
  FakePathProvider() {
    tempDir = Directory.systemTemp.createTempSync('aa_test_tmp');
    docDir = Directory.systemTemp.createTempSync('aa_test_doc');
  }

  late final Directory tempDir;
  late final Directory docDir;

  @override
  Future<String?> getTemporaryPath() async => tempDir.path;

  @override
  Future<String?> getApplicationDocumentsPath() async => docDir.path;

  void cleanup() {
    try {
      tempDir.deleteSync(recursive: true);
      docDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 构造测试用账户行
Account mkAccount(
  String id, {
  String name = '现金',
  String emoji = '💵',
  int type = 0,
  int initBalance = 0,
  bool includeNetWorth = true,
  int sort = 0,
  int createdAt = 0,
}) =>
    Account(
      id: id,
      name: name,
      emoji: emoji,
      type: type,
      initBalance: initBalance,
      includeNetWorth: includeNetWorth,
      sort: sort,
      createdAt: createdAt,
    );

/// 构造测试用账单行
Bill mkBill(
  String id, {
  int type = 0,
  int amount = 100,
  String? categoryId,
  String accountId = 'acc_cash',
  String? toAccountId,
  int dateMs = 0,
  String note = '',
  bool isAa = false,
  String? aaGroupId,
  String? settlementId,
  int createdAt = 0,
  int updatedAt = 0,
  int? deletedAt,
}) =>
    Bill(
      id: id,
      type: type,
      amount: amount,
      categoryId: categoryId,
      accountId: accountId,
      toAccountId: toAccountId,
      dateMs: dateMs,
      note: note,
      isAa: isAa,
      aaGroupId: aaGroupId,
      settlementId: settlementId,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deletedAt: deletedAt,
    );

/// 与业务页一致的本地化壳：中文 locale + Material 本地化（日期选择器等需要）
Widget localizedApp(Widget child) => MaterialApp(
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      home: Scaffold(body: child),
    );

/// 把页面装进 ProviderScope（内存库）+ 本地化壳，泵一帧。
/// 返回实际使用的数据库，测试结尾须调用 [disposePage] 卸载并关闭，
/// 否则 drift watch 流的 pending timer 会让 testWidgets 报错
/// [overrides] 元素须为 riverpod 的 override 表达式（riverpod 3 不再公开
/// Override 类型，这里以 List<dynamic> 传递）
Future<AppDatabase> pumpPage(
  WidgetTester tester,
  Widget page, {
  AppDatabase? db,
  List<dynamic> overrides = const [],
}) async {
  final database = db ?? TestAppDatabase();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        ...overrides,
      ],
      child: localizedApp(page),
    ),
  );
  await tester.pumpAndSettle();
  return database;
}

/// [pumpPage] 的配对清理：卸载组件树、关闭数据库（停掉 watch 流的 timer）
Future<void> disposePage(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
  await db.close();
}

// ---------------------------------------------------------------------------
// 平台插件 mock：FilePicker / SharePlus / ImagePicker / ML Kit
// ---------------------------------------------------------------------------

base class _FakePlatformFile extends fpi.PlatformFile {
  _FakePlatformFile(this.p);
  final String p;

  @override
  String get name => p.split(Platform.pathSeparator).last;

  @override
  Uri get uri => Uri.file(p);

  @override
  XFile get xFile => XFile(p);

  @override
  int? lengthSync() => 0;

  @override
  Future<int?> length() async => 0;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(0);

  @override
  Stream<Uint8List> readAsByteStream() => const Stream.empty();
}

/// pickFile 返回 [nextPath]（null 模拟用户取消）
class FakeFilePicker extends fpi.FilePickerPlatform {
  FakeFilePicker(this.nextPath);
  final String? nextPath;

  @override
  Future<fpi.PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    fpi.FileType type = fpi.FileType.any,
    List<String>? allowedExtensions,
    Function(fpi.FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    fpi.AndroidOptions androidOptions = const fpi.AndroidOptions(),
    fpi.DarwinOptions darwinOptions = const fpi.DarwinOptions(),
    fpi.WindowsOptions windowsOptions = const fpi.WindowsOptions(),
    fpi.LinuxOptions linuxOptions = const fpi.LinuxOptions(),
    fpi.WebOptions webOptions = const fpi.WebOptions(),
  }) async =>
      nextPath == null ? null : _FakePlatformFile(nextPath!);
}

/// SharePlus.instance.share 的假实现，记录参数
class FakeSharePlatform extends spi.SharePlatform {
  spi.ShareParams? lastParams;

  @override
  Future<spi.ShareResult> share(spi.ShareParams params) async {
    lastParams = params;
    return const spi.ShareResult('ok', spi.ShareResultStatus.success);
  }
}

/// ImagePicker.pickImage 的假实现，记录来源并返回固定文件
class FakeImagePickerPlatform extends ipi.ImagePickerPlatform {
  FakeImagePickerPlatform(this.nextPath);
  final String? nextPath;

  ip.ImageSource? lastSource;

  @override
  Future<XFile?> getImageFromSource({
    required ip.ImageSource source,
    ipi.ImagePickerOptions options = const ipi.ImagePickerOptions(),
  }) async {
    lastSource = source;
    return nextPath == null ? null : XFile(nextPath!);
  }
}

/// mock ML Kit 文本识别通道（channel: google_mlkit_text_recognizer）
/// [linesByBlock] 每个 block 的文本行列表；设为 null 时抛平台异常
void mockMlKitTextRecognition(List<List<String>>? linesByBlock) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('google_mlkit_text_recognizer'), (call) async {
    if (call.method != 'vision#startTextRecognizer') return null;
    if (linesByBlock == null) {
      throw PlatformException(code: 'unavailable');
    }
    Map<String, Object?> line(String text) => {
          'text': text,
          'rect': const <String, Object>{},
          'recognizedLanguages': const <String>[],
          'points': const <Object>[],
          'confidence': null,
          'angle': null,
          'elements': const <Object>[],
        };
    return <String, Object?>{
      'text': [
        for (final block in linesByBlock) ...block,
      ].join('\n'),
      'blocks': [
        for (final block in linesByBlock)
          <String, Object?>{
            'text': block.join('\n'),
            'rect': const <String, Object>{},
            'recognizedLanguages': const <String>[],
            'points': const <Object>[],
            'lines': [for (final l in block) line(l)],
          }
      ],
    };
  });
}

void clearMlKitMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('google_mlkit_text_recognizer'), null);
}

/// 等待 riverpod StreamProvider 首批数据就绪（数据库 watch 流两拍）
Future<void> settleProviders(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
}
