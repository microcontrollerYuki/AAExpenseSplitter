import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/pages/account_info_page.dart';
import 'package:aa_expense_splitter/pages/accounts_page.dart';

import '../helpers/test_support.dart';

class _GatedAccountDatabase extends TestAppDatabase {
  bool holdSave = false;
  bool holdDeleteCount = false;
  int heldSaveCalls = 0;
  int heldCountCalls = 0;
  int deleteCalls = 0;
  final saveEntered = Completer<void>();
  final releaseSave = Completer<void>();
  final saveFinished = Completer<void>();
  final countEntered = Completer<void>();
  final releaseCount = Completer<void>();
  final countFinished = Completer<void>();

  @override
  Future<void> upsertAccount({
    required String id,
    required String name,
    required String emoji,
    required int type,
    required int initBalance,
    required bool includeNetWorth,
    required int sort,
    String? currency,
    Account? expected,
  }) async {
    final gated = holdSave;
    if (gated) {
      heldSaveCalls++;
      if (!saveEntered.isCompleted) saveEntered.complete();
      await releaseSave.future;
    }
    try {
      await super.upsertAccount(
        id: id,
        name: name,
        emoji: emoji,
        type: type,
        initBalance: initBalance,
        includeNetWorth: includeNetWorth,
        sort: sort,
        currency: currency,
        expected: expected,
      );
    } finally {
      if (gated && !saveFinished.isCompleted) saveFinished.complete();
    }
  }

  @override
  Future<int> billCountOfAccount(
    String accountId, {
    bool includeDeleted = false,
  }) async {
    final gated = holdDeleteCount && includeDeleted;
    if (gated) {
      heldCountCalls++;
      if (!countEntered.isCompleted) countEntered.complete();
      await releaseCount.future;
    }
    try {
      return await super.billCountOfAccount(
        accountId,
        includeDeleted: includeDeleted,
      );
    } finally {
      if (gated && !countFinished.isCompleted) countFinished.complete();
    }
  }

  @override
  Future<void> deleteAccount(String id) async {
    deleteCalls++;
    await super.deleteAccount(id);
  }

  void releaseAll() {
    if (!releaseSave.isCompleted) releaseSave.complete();
    if (!releaseCount.isCompleted) releaseCount.complete();
  }
}

// Keep a real route below AccountsPage. An accidental extra pop must expose
// this sentinel instead of being hidden by Navigator's unpoppable home route.
class _AccountHarness extends StatelessWidget {
  const _AccountHarness();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text('根页面保留'),
      TextButton(
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const AccountsPage())),
        child: const Text('打开账本'),
      ),
    ],
  );
}

Future<void> _waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 80 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(condition(), isTrue, reason: '账户异步操作应在两秒内完成');
  await settleProviders(tester);
}

Future<void> _openEditor(WidgetTester tester, AppDatabase db) async {
  await db.upsertAccount(
    id: 'lifecycle',
    name: '生命周期账户',
    emoji: '💳',
    type: 3,
    initBalance: 100,
    includeNetWorth: true,
    sort: -1,
  );
  await pumpPage(tester, const _AccountHarness(), db: db);
  await tester.tap(find.text('打开账本'));
  await settleProviders(tester);
  await tester.tap(find.text('生命周期账户'));
  await settleProviders(tester);
  expect(find.byType(AccountInfoPage), findsOneWidget);
  await tester.tap(find.text('修改'));
  await settleProviders(tester);
  expect(find.byType(AlertDialog), findsOneWidget);
}

Future<void> _tryClosingBusyDialog(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, '取消'));
  await settleProviders(tester);
  expect(find.byType(AlertDialog), findsOneWidget);
  await tester.binding.handlePopRoute();
  await settleProviders(tester);
  expect(find.byType(AlertDialog), findsOneWidget);
  expect(find.text('根页面保留'), findsNothing);
}

Future<void> _cleanup(WidgetTester tester, _GatedAccountDatabase db) async {
  await tester.runAsync(() async => db.releaseAll());
  if (db.saveEntered.isCompleted) {
    await _waitUntil(tester, () => db.saveFinished.isCompleted);
  }
  if (db.countEntered.isCompleted) {
    await _waitUntil(tester, () => db.countFinished.isCompleted);
  }
  await disposePage(tester, db);
}

void main() {
  testWidgets('账户保存挂起时取消及系统返回不关窗口，完成只返回账户信息', (tester) async {
    late _GatedAccountDatabase db;
    // Gates must live in the real async zone, as the DAO callback does.
    await tester.runAsync(() async => db = _GatedAccountDatabase());
    try {
      await _openEditor(tester, db);
      await tester.enterText(find.widgetWithText(TextField, '名称'), '保存后的账户');
      await tester.enterText(
        find.widgetWithText(TextField, '期初余额（元）'),
        '12.34',
      );
      tester.testTextInput.hide();
      db.holdSave = true;
      await tester.runAsync(() async => tester.tap(find.text('保存')));
      await _waitUntil(tester, () => db.saveEntered.isCompleted);
      expect(db.heldSaveCalls, 1);
      expect((await db.getAccount('lifecycle'))!.name, '生命周期账户');
      await _tryClosingBusyDialog(tester);
      expect(db.heldSaveCalls, 1);

      await tester.runAsync(() async => db.releaseAll());
      await _waitUntil(
        tester,
        () =>
            db.saveFinished.isCompleted &&
            find.byType(AlertDialog).evaluate().isEmpty,
      );
      expect(find.byType(AccountInfoPage), findsOneWidget);
      expect(find.text('💳 保存后的账户'), findsOneWidget);
      expect(find.text('根页面保留'), findsNothing);
      final saved = (await db.getAccount('lifecycle'))!;
      expect(saved.name, '保存后的账户');
      expect(saved.currency, 'CNY');
      expect(saved.initBalance, 1234);
      expect(db.heldSaveCalls, 1);
      expect(db.deleteCalls, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await _cleanup(tester, db);
    }
  });

  testWidgets('账户删除预检挂起时不能取消或返回，完成仅返回账本且不多pop', (tester) async {
    late _GatedAccountDatabase db;
    await tester.runAsync(() async => db = _GatedAccountDatabase());
    try {
      await _openEditor(tester, db);
      // Initial currency-lock loading has completed. Only the delete-time
      // includeDeleted preflight is held, so it can race with closing the UI.
      db.holdDeleteCount = true;
      await tester.runAsync(() async => tester.tap(find.text('删除')));
      await _waitUntil(tester, () => db.countEntered.isCompleted);
      expect(db.heldCountCalls, 1);
      expect(db.deleteCalls, 0);
      expect(await db.getAccount('lifecycle'), isNotNull);
      await _tryClosingBusyDialog(tester);
      expect(db.heldCountCalls, 1);
      expect(db.deleteCalls, 0);

      await tester.runAsync(() async => db.releaseAll());
      await _waitUntil(
        tester,
        () =>
            db.countFinished.isCompleted &&
            find.byType(AlertDialog).evaluate().isEmpty,
      );
      expect(find.byType(AccountInfoPage), findsNothing);
      expect(find.byType(AccountsPage), findsOneWidget);
      expect(find.text('根页面保留'), findsNothing);
      expect(await db.getAccount('lifecycle'), isNull);
      expect(db.heldCountCalls, 1);
      expect(db.deleteCalls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      await _cleanup(tester, db);
    }
  });

  testWidgets('320窄屏大字体及键盘下可滚动选择币种输入最大JPY并保存', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final db = await pumpPage(tester, const AccountsPage());
    await tester.tap(find.byTooltip('添加账户'));
    await settleProviders(tester);
    await tester.enterText(find.widgetWithText(TextField, '名称'), '窄屏日元账户');
    final currencyField = find.byKey(const ValueKey('account_currency'));
    await tester.ensureVisible(currencyField);
    await tester.tap(currencyField);
    await settleProviders(tester);
    await tester.ensureVisible(find.text('JPY · 日元').last);
    await settleProviders(tester);
    await tester.tap(find.text('JPY · 日元').last);
    await settleProviders(tester);
    final balanceField = find.widgetWithText(TextField, '期初余额（JPY）');
    await tester.ensureVisible(balanceField);
    await tester.enterText(balanceField, '9223372036854775807');
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await settleProviders(tester);
    expect(
      MediaQuery.textScalerOf(tester.element(balanceField)).scale(10),
      closeTo(18, 0.001),
    );
    final currencyButton = find
        .descendant(of: currencyField, matching: find.text('JPY · 日元'))
        .first;
    await tester.ensureVisible(currencyButton);
    await settleProviders(tester);
    expect(
      currencyButton.hitTestable(),
      findsOneWidget,
      reason: '可点击币种文字须位于滚动视口内',
    );
    await tester.ensureVisible(balanceField);
    await settleProviders(tester);
    expect(balanceField.hitTestable(), findsOneWidget);
    expect(
      tester.widget<TextField>(balanceField).controller!.text,
      '9,223,372,036,854,775,807',
    );
    final dialogCard = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Material),
        )
        .first;
    expect(tester.getRect(dialogCard).bottom, lessThanOrEqualTo(300));
    expect(tester.takeException(), isNull);
    tester.testTextInput.hide();
    tester.view.resetViewInsets();
    await settleProviders(tester);
    await tester.runAsync(() async => tester.tap(find.text('保存')));
    await _waitUntil(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
    final saved = (await db.getAllAccounts()).singleWhere(
      (account) => account.name == '窄屏日元账户',
    );
    expect(saved.currency, 'JPY');
    expect(saved.initBalance, 9223372036854775807);
    expect(tester.takeException(), isNull);
    await disposePage(tester, db);
  });
}
