import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/widgets/year_month_picker.dart';

import '../helpers/test_support.dart';

Finder monthKey(String key) => find.byKey(ValueKey(key));

Future<void> pumpMonthHost(
  WidgetTester tester, {
  required DateTime initial,
  required void Function(DateTime?) onResult,
}) async {
  await tester.pumpWidget(
    localizedApp(
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              final result = await showYearMonthPicker(
                context: context,
                initialMonth: initial,
              );
              onResult(result);
            },
            child: const Text('打开年月选择'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openMonthDialog(WidgetTester tester) async {
  await tester.tap(find.text('打开年月选择'));
  await tester.pumpAndSettle();
  expect(find.byType(YearMonthPickerDialog), findsOneWidget);
  expect(find.text('选择年月'), findsOneWidget);
}

Future<void> tapMonthControl(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void expectMonthSelected(WidgetTester tester, int month, bool selected) {
  final button = monthKey('month-picker-month-$month');
  final selectedSemantics = find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.selected != null,
  );
  final descendant = find.descendant(
    of: button,
    matching: selectedSemantics,
    matchRoot: true,
  );
  final semantics = descendant.evaluate().isNotEmpty
      ? descendant.first
      : find.ancestor(of: button, matching: selectedSemantics).first;
  expect(tester.widget<Semantics>(semantics).properties.selected, selected);
}

IconButton yearArrow(WidgetTester tester, String tooltip) {
  final target = find.byTooltip(tooltip);
  final ancestors = find.ancestor(
    of: target,
    matching: find.byType(IconButton),
  );
  final button = ancestors.evaluate().isNotEmpty
      ? ancestors.first
      : find
            .descendant(
              of: target,
              matching: find.byType(IconButton),
              matchRoot: true,
            )
            .first;
  return tester.widget<IconButton>(button);
}

void main() {
  testWidgets('初始年月选中正确，确认返回本地月首并清除原始日时分秒', (tester) async {
    final results = <DateTime?>[];
    await pumpMonthHost(
      tester,
      initial: DateTime.utc(2026, 10, 25, 13, 45, 33),
      onResult: results.add,
    );
    await openMonthDialog(tester);
    expect(find.text('2026年'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNWidgets(12));
    expectMonthSelected(tester, 10, true);
    expectMonthSelected(tester, 9, false);
    expect(results, isEmpty);
    await tapMonthControl(tester, monthKey('month-picker-confirm'));
    expect(results, [DateTime(2026, 10, 1)]);
    expect(results.single!.isUtc, isFalse);
    expect(results.single!.hour, 0);
    expect(results.single!.millisecond, 0);
    expect(find.byType(YearMonthPickerDialog), findsNothing);
  });

  testWidgets('年份箭头跨年后选月只修改草稿，确认才返回新年月', (tester) async {
    final results = <DateTime?>[];
    await pumpMonthHost(
      tester,
      initial: DateTime(2026, 12, 31),
      onResult: results.add,
    );
    await openMonthDialog(tester);
    await tapMonthControl(tester, find.byTooltip('下一年'));
    expect(find.text('2027年'), findsOneWidget);
    expectMonthSelected(tester, 12, true);
    await tapMonthControl(tester, monthKey('month-picker-month-1'));
    expectMonthSelected(tester, 1, true);
    expectMonthSelected(tester, 12, false);
    expect(results, isEmpty);
    await tapMonthControl(tester, monthKey('month-picker-confirm'));
    expect(results.single, DateTime(2027, 1, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消、系统返回和遮罩关闭都丢弃年月草稿而不改变外部选择', (tester) async {
    final initial = DateTime(2026, 10, 1);
    var external = initial;
    final results = <DateTime?>[];
    await pumpMonthHost(
      tester,
      initial: initial,
      onResult: (result) {
        results.add(result);
        if (result != null) external = result;
      },
    );
    for (final dismissal in ['cancel', 'system back', 'barrier']) {
      await openMonthDialog(tester);
      await tapMonthControl(tester, find.byTooltip('下一年'));
      await tapMonthControl(tester, monthKey('month-picker-month-4'));
      expect(external, initial, reason: dismissal);
      switch (dismissal) {
        case 'cancel':
          await tapMonthControl(tester, find.text('取消'));
          break;
        case 'system back':
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          break;
        case 'barrier':
          await tester.tapAt(const Offset(1, 1));
          await tester.pumpAndSettle();
          break;
      }
      expect(external, initial, reason: dismissal);
      expect(results.last, isNull, reason: dismissal);
      expect(find.byType(YearMonthPickerDialog), findsNothing);
    }
    expect(results, [null, null, null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击年份时当前年可见，实际选择年份后返回月份并保留当前月份', (tester) async {
    final results = <DateTime?>[];
    await pumpMonthHost(
      tester,
      initial: DateTime(2026, 10, 18),
      onResult: results.add,
    );
    await openMonthDialog(tester);
    await tapMonthControl(tester, monthKey('month-picker-year'));
    expect(find.text('2026').hitTestable(), findsOneWidget);
    await tapMonthControl(tester, find.text('2027'));
    expect(find.text('2027年'), findsOneWidget);
    expectMonthSelected(tester, 10, true);
    await tapMonthControl(tester, monthKey('month-picker-month-7'));
    await tapMonthControl(tester, monthKey('month-picker-confirm'));
    expect(results.single, DateTime(2027, 7, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('320×480及1.8倍系统字体能滚动选择和确认，不发生布局溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final results = <DateTime?>[];
    await pumpMonthHost(
      tester,
      initial: DateTime(2026, 1, 20),
      onResult: results.add,
    );
    await openMonthDialog(tester);
    final dialogContext = tester.element(find.byType(YearMonthPickerDialog));
    expect(MediaQuery.sizeOf(dialogContext), const Size(320, 480));
    expect(
      MediaQuery.textScalerOf(dialogContext).scale(10),
      closeTo(18, 0.001),
    );
    await tapMonthControl(tester, monthKey('month-picker-month-12'));
    expectMonthSelected(tester, 12, true);
    await tapMonthControl(tester, monthKey('month-picker-confirm'));
    expect(results.single, DateTime(2026, 12, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字体打开年份时当前年真实可见，可选邻近年份并确认', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final results = <DateTime?>[];
    await pumpMonthHost(
      tester,
      initial: DateTime(2026, 10, 18),
      onResult: results.add,
    );
    await openMonthDialog(tester);
    final dialogContext = tester.element(find.byType(YearMonthPickerDialog));
    expect(
      MediaQuery.textScalerOf(dialogContext).scale(10),
      closeTo(18, 0.001),
    );
    await tapMonthControl(tester, monthKey('month-picker-year'));
    // 不先滚动补救定位：打开年份列表就应让用户看见自己的当前年份。
    expect(find.text('2026').hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('2027'),
      64,
      maxScrolls: 3,
      scrollable: find
          .descendant(
            of: find.byType(YearMonthPickerDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tapMonthControl(tester, find.text('2027'));
    expect(find.text('2027年'), findsOneWidget);
    expectMonthSelected(tester, 10, true);
    await tapMonthControl(tester, monthKey('month-picker-confirm'));
    expect(results.single, DateTime(2027, 10, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('年份边界禁用相应箭头，超范围初始年扩大边界且可以确认', (tester) async {
    for (final year in [1, 9999, 0, 10000]) {
      final results = <DateTime?>[];
      await pumpMonthHost(
        tester,
        initial: DateTime(year, 6, 21),
        onResult: results.add,
      );
      await openMonthDialog(tester);
      expect(find.text('$year年'), findsOneWidget);
      if (year <= 1) {
        expect(yearArrow(tester, '上一年').onPressed, isNull);
        expect(yearArrow(tester, '下一年').onPressed, isNotNull);
      } else {
        expect(yearArrow(tester, '上一年').onPressed, isNotNull);
        expect(yearArrow(tester, '下一年').onPressed, isNull);
      }
      await tapMonthControl(tester, monthKey('month-picker-month-3'));
      await tapMonthControl(tester, monthKey('month-picker-confirm'));
      expect(results.single, DateTime(year, 3, 1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('连续打开的两个窗口独立初始化，不沿用上次草稿或已确认年月', (tester) async {
    final results = <DateTime?>[];
    await pumpMonthHost(
      tester,
      initial: DateTime(2026, 10, 10),
      onResult: results.add,
    );
    await openMonthDialog(tester);
    await tapMonthControl(tester, find.byTooltip('下一年'));
    await tapMonthControl(tester, monthKey('month-picker-month-2'));
    await tapMonthControl(tester, monthKey('month-picker-confirm'));
    expect(results, [DateTime(2027, 2, 1)]);
    await openMonthDialog(tester);
    expect(find.text('2026年'), findsOneWidget);
    expectMonthSelected(tester, 10, true);
    expectMonthSelected(tester, 2, false);
    await tapMonthControl(tester, find.text('取消'));
    expect(results, [DateTime(2027, 2, 1), null]);
    expect(tester.takeException(), isNull);
  });
}
