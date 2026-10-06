import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/data/presets.dart';

void main() {
  test('预置支出分类完整且 id 唯一', () {
    expect(kPresetExpenseCategories.length, 12);
    final ids = kPresetExpenseCategories.map((c) => c.id).toSet();
    expect(ids.length, kPresetExpenseCategories.length);
    expect(kPresetExpenseCategories.every((c) => c.kind == 0), isTrue);
    expect(
        kPresetExpenseCategories.any((c) => c.id == 'cat_food' && c.name == '餐饮'),
        isTrue);
  });

  test('预置收入分类完整且 id 唯一', () {
    expect(kPresetIncomeCategories.length, 5);
    expect(kPresetIncomeCategories.every((c) => c.kind == 1), isTrue);
  });

  test('预置账户：4 个且类型字段合法', () {
    expect(kPresetAccounts.length, 4);
    expect(kPresetAccounts.map((a) => a.id).toSet().length, 4);
    expect(kPresetAccounts.every((a) => a.type >= 0 && a.type <= 4), isTrue);
    expect(kPresetAccounts.first.id, 'acc_cash');
  });

  test('AA 专用常量', () {
    expect(kAaMarkerCategoryId, 'cat_aa_marker');
    expect(kAaCreditAccountId, 'acc_aa_credit');
    expect(kAccountEmojiChoices, isNotEmpty);
    expect(kAccountTypeNames.length, 5);
  });
}
