import 'dart:async';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/edit_bill_page.dart';
import 'package:aa_expense_splitter/utils/currency.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../helpers/test_support.dart';

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; finder.evaluate().isEmpty && attempt < 8; attempt++) {
    final lists = find.byType(ListView);
    expect(lists, findsWidgets);
    await tester.drag(lists.last, const Offset(0, -180));
    await settleProviders(tester);
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await settleProviders(tester);
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
  await settleProviders(tester);
}

Future<TestAppDatabase> _seed() async {
  final db = TestAppDatabase();
  await db.getAllAccounts();
  for (final currency in [Currency.usd, Currency.jpy]) {
    await db.upsertAccount(
      id: currency.code.toLowerCase(),
      name: '${currency.displayName}钱包',
      emoji: '💳',
      type: 0,
      initBalance: 0,
      includeNetWorth: true,
      sort: 20 + currency.index,
      currency: currency.code,
    );
  }
  return db;
}

Future<void> _open(
  WidgetTester tester,
  TestAppDatabase db,
  List<String> lines, {
  Bill? bill,
}) async {
  final previousPicker = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = FakeImagePickerPlatform('/synthetic.jpg');
  mockMlKitTextRecognition([lines]);
  addTearDown(() {
    ImagePickerPlatform.instance = previousPicker;
    clearMlKitMock();
  });
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
  await _tap(tester, find.byTooltip('图片识别记账'));
  await _tap(tester, find.text('从相册选择'));
  expect(find.text('图片识别结果'), findsOneWidget);
}

Future<void> _selectAccount(WidgetTester tester, String name) async {
  await _tap(tester, find.text('账户'));
  await _tap(tester, find.widgetWithText(ListTile, name));
}

Future<void> _save(WidgetTester tester) => _tap(
  tester,
  find.descendant(of: find.byType(NumberPad), matching: find.text('保存')),
);

void main() {
  for (final sample in [
    (currency: Currency.usd, text: 'USD 12.34', input: '12.34', units: 1234),
    (currency: Currency.jpy, text: 'JPY 1234', input: '1234', units: 1234),
  ]) {
    testWidgets('OCR明确${sample.currency.code}金额采用后按原币精度保存', (tester) async {
      final db = await _seed();
      await _open(tester, db, [
        '付款成功',
        '实付金额',
        sample.text,
        '交易时间',
        '2026-10-03 14:25:00',
        '餐饮测试商户',
      ]);
      expect(
        tester.widget<TextField>(_key('ocr-amount-input')).controller!.text,
        sample.input,
      );
      expect(
        find.widgetWithText(
          ActionChip,
          '${sample.currency.code} ${sample.currency.displayName}',
        ),
        findsOneWidget,
      );
      await _selectAccount(tester, '${sample.currency.displayName}钱包');
      await _tap(tester, find.text('采用并填入'));
      expect(
        find.descendant(
          of: _key('entry-currency'),
          matching: find.text(sample.currency.code),
        ),
        findsOneWidget,
      );
      expect(_key('entry-account-amount'), findsNothing);
      await _save(tester);

      final saved = (await db.getAllBills()).single;
      expect(saved.currency, sample.currency.code);
      expect(saved.amount, sample.units);
      expect(saved.accountAmount, sample.units);
      expect(saved.accountId, sample.currency.code.toLowerCase());
      expect(
        saved.dateMs,
        DateTime(2026, 10, 3, 14, 25).millisecondsSinceEpoch,
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    });
  }

  testWidgets('OCR选择2100年末后主表单可重新打开日期并保留原币金额', (tester) async {
    final db = await _seed();
    await _open(tester, db, [
      '合计 USD 12.34',
      '交易时间 2026-10-03 14:25:00',
      '餐饮测试商户',
    ]);
    await _selectAccount(tester, '美元钱包');
    await _tap(tester, find.text('日期'));
    final dateDialog = find.byType(DatePickerDialog);
    final localizations = MaterialLocalizations.of(tester.element(dateDialog));
    await _tap(tester, find.byTooltip(localizations.inputDateModeButtonLabel));
    await tester.enterText(
      find.descendant(
        of: find.byType(InputDatePickerFormField),
        matching: find.byType(TextField),
      ),
      localizations.formatCompactDate(DateTime(2100, 12, 31)),
    );
    tester.testTextInput.hide();
    await _tap(
      tester,
      find.descendant(
        of: dateDialog,
        matching: find.text(localizations.okButtonLabel),
      ),
    );
    await _tap(
      tester,
      find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.text(localizations.okButtonLabel),
      ),
    );
    await _tap(tester, find.text('采用并填入'));
    await _tap(tester, find.widgetWithText(ActionChip, '12月31日 14:25'));
    // 旧主表单的上限只有 2100-01-01，这里会因初始日期越界而断言。
    expect(tester.takeException(), isNull);
    expect(dateDialog, findsOneWidget);
    expect(
      tester.widget<DatePickerDialog>(dateDialog).initialDate,
      DateTime(2100, 12, 31),
    );
    Navigator.of(tester.element(dateDialog)).pop();
    await settleProviders(tester);
    await _save(tester);

    final saved = (await db.getAllBills()).single;
    expect(saved.dateMs, DateTime(2100, 12, 31, 14, 25).millisecondsSinceEpoch);
    expect(saved.currency, 'USD');
    expect(saved.amount, 1234);
    expect(saved.accountAmount, 1234);
    expect(saved.accountId, 'usd');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('OCR含糊美元符号不擅自指定币种，用户确认USD后才可采用', (tester) async {
    final db = await _seed();
    await _open(tester, db, ['付款成功', '实付金额', r'$12.34', '餐饮测试商户']);
    expect(find.widgetWithText(ActionChip, '币种待确认'), findsOneWidget);
    await _tap(tester, find.text('采用并填入'));
    expect(find.text('请选择并确认币种'), findsOneWidget);
    expect(find.text('图片识别结果'), findsOneWidget);
    expect(await db.getAllBills(), isEmpty);
    await _tap(tester, _key('ocr-currency'));
    await _tap(tester, find.widgetWithText(ListTile, '美元 USD'));
    await _selectAccount(tester, '美元钱包');
    await _tap(tester, find.text('采用并填入'));
    await _save(tester);

    final saved = (await db.getAllBills()).single;
    expect(saved.currency, 'USD');
    expect(saved.amount, 1234);
    expect(saved.accountAmount, 1234);
    expect(saved.accountId, 'usd');
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  testWidgets('取消OCR人民币候选保留编辑中的美元账单全部字段', (tester) async {
    final db = await _seed();
    await db.upsertBill(
      id: 'old',
      type: 0,
      amount: 1029,
      currency: 'USD',
      accountId: 'usd',
      categoryId: 'cat_food',
      dateMs: 1791027900321,
      createdAt: 77,
      note: '原美元账单',
    );
    final before = (await db.getAllBills()).single;
    await _open(tester, db, [
      '付款成功',
      '实付金额',
      'CNY 99.99',
      '其他新商户',
    ], bill: before);
    Navigator.of(tester.element(find.text('图片识别结果'))).pop();
    await settleProviders(tester);
    expect(
      find.descendant(of: _key('entry-currency'), matching: find.text('USD')),
      findsOneWidget,
    );
    await _save(tester);

    final after = (await db.getAllBills()).single;
    expect(
      after.toJson()..remove('updatedAt'),
      before.toJson()..remove('updatedAt'),
    );
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });

  for (final failed in [false, true]) {
    testWidgets('系统返回取消OCR加载后识别${failed ? '失败' : '完成'}不会退掉编辑页或打开结果', (
      tester,
    ) async {
      final previousPicker = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = FakeImagePickerPlatform('/delayed.jpg');
      final recognition = Completer<Object?>();
      final recognitionStarted = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('google_mlkit_text_recognizer'),
            (call) async {
              if (call.method != 'vision#startTextRecognizer') return null;
              recognitionStarted.complete();
              return recognition.future;
            },
          );
      addTearDown(() {
        if (!recognition.isCompleted) {
          recognition.complete(<String, Object?>{'text': '', 'blocks': []});
        }
        ImagePickerPlatform.instance = previousPicker;
        clearMlKitMock();
      });
      final db = await _seed();
      await db.upsertBill(
        id: 'old',
        type: 0,
        amount: 1029,
        currency: 'USD',
        accountId: 'usd',
        categoryId: 'cat_food',
        dateMs: 1791027900321,
        createdAt: 77,
        note: '识别取消前原账',
      );
      final before = (await db.getAllBills()).single;
      await pumpPage(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => EditBillPage(bill: before),
              ),
            ),
            child: const Text('开始'),
          ),
        ),
        db: db,
      );
      await _tap(tester, find.text('开始'));
      await _tap(tester, find.byTooltip('图片识别记账'));
      // 识别中有循环进度动画，此处使用有界泵帧而非等待所有动画结束。
      await tester.runAsync(() async {
        await tester.tap(find.text('从相册选择'));
      });
      // picker 和路由 Future 在测试时钟中继续；先泵帧，不能在 runAsync
      // 中等待一个尚未经过这些帧才能触发的 MethodChannel 调用。
      for (
        var frame = 0;
        !recognitionStarted.isCompleted && frame < 10;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
        });
      }
      expect(recognitionStarted.isCompleted, isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在识别…'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在识别…'), findsNothing);
      expect(find.byType(EditBillPage), findsOneWidget);

      await tester.runAsync(() async {
        if (failed) {
          recognition.completeError(PlatformException(code: 'cancelled-late'));
        } else {
          recognition.complete(<String, Object?>{
            'text': 'USD 99.99',
            'blocks': [],
          });
        }
        await Future<void>.delayed(Duration.zero);
      });
      await settleProviders(tester);
      expect(find.byType(EditBillPage), findsOneWidget);
      expect(find.text('图片识别结果'), findsNothing);
      expect(find.textContaining('识别失败'), findsNothing);
      expect((await db.getAllBills()).single, before);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '识别取消前原账',
      );
      expect(tester.takeException(), isNull);
      await disposePage(tester, db);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
