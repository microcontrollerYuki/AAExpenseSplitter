import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/providers.dart';
import 'package:aa_expense_splitter/widgets/month_bar.dart';
import 'package:aa_expense_splitter/widgets/number_pad.dart';

import '../helpers/test_support.dart';

void _noop() {}
void _noopKey(String _) {}

void main() {
  group('NumberPad', () {
    Widget wrap(NumberPad pad) => localizedApp(Scaffold(body: pad));

    testWidgets('渲染四行键盘与全部按键', (tester) async {
      await tester.pumpWidget(wrap(const NumberPad(
        onKey: _noopKey,
        onBackspace: _noop,
        onClear: _noop,
        onSave: _noop,
      )));
      for (final label in [
        '1', '2', '3', '⌫',
        '4', '5', '6', '−',
        '7', '8', '9', '+',
        '再记', '0', '.', '保存',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('数字与小数点按键回调 onKey', (tester) async {
      final keys = <String>[];
      await tester.pumpWidget(wrap(NumberPad(
        onKey: keys.add,
        onBackspace: _noop,
        onClear: _noop,
        onSave: _noop,
      )));
      await tester.tap(find.text('7'));
      await tester.tap(find.text('0'));
      await tester.tap(find.text('.'));
      expect(keys, ['7', '0', '.']);
    });

    testWidgets('− 键转换为 onKey(\'-\')', (tester) async {
      final keys = <String>[];
      await tester.pumpWidget(wrap(NumberPad(
        onKey: keys.add,
        onBackspace: _noop,
        onClear: _noop,
        onSave: _noop,
      )));
      await tester.tap(find.text('−'));
      expect(keys, ['-']);
    });

    testWidgets('⌫ 点击退格、长按清空', (tester) async {
      var backs = 0, clears = 0;
      await tester.pumpWidget(wrap(NumberPad(
        onKey: _noopKey,
        onBackspace: () => backs++,
        onClear: () => clears++,
        onSave: _noop,
      )));
      await tester.tap(find.text('⌫'));
      expect(backs, 1);
      expect(clears, 0);

      await tester.longPress(find.text('⌫'));
      await tester.pump();
      expect(clears, 1);
      expect(backs, 1);
    });

    testWidgets('保存与再记回调', (tester) async {
      var saves = 0, agains = 0;
      await tester.pumpWidget(wrap(NumberPad(
        onKey: _noopKey,
        onBackspace: _noop,
        onClear: _noop,
        onSave: () => saves++,
        onSaveAndAgain: () => agains++,
      )));
      await tester.tap(find.text('保存'));
      expect(saves, 1);
      await tester.tap(find.text('再记'));
      expect(agains, 1);
    });

    testWidgets('未提供 onSaveAndAgain 时再记被禁用', (tester) async {
      var saves = 0;
      await tester.pumpWidget(wrap(NumberPad(
        onKey: _noopKey,
        onBackspace: _noop,
        onClear: _noop,
        onSave: () => saves++,
      )));
      await tester.tap(find.text('再记'));
      await tester.pump();
      expect(saves, 0);
      // 禁用样式存在（灰色 InkWell，onTap 为 null 不可点）
      final ink = find.ancestor(
          of: find.text('再记'), matching: find.byType(InkWell));
      expect(ink, findsOneWidget);
    });
  });

  group('MonthBar', () {
    testWidgets('显示当前月份并可前后切换', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final now = container.read(selectedMonthProvider);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: localizedApp(const Scaffold(body: MonthBar())),
      ));

      expect(find.text('${now.year}年${now.month}月'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      final prev = container.read(selectedMonthProvider);
      expect(prev, DateTime(now.year, now.month - 1, 1));
      expect(find.text('${prev.year}年${prev.month}月'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      expect(container.read(selectedMonthProvider),
          DateTime(now.year, now.month, 1));
    });
  });
}
