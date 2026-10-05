/// 预置种子数据：分类与账户（M1 固定，自定义能力放第二批）
class PresetCategory {
  final String id;
  final String emoji;
  final String name;
  final int kind; // 0 支出 / 1 收入 / 2 不计收支
  const PresetCategory(this.id, this.emoji, this.name, this.kind);
}

class PresetAccount {
  final String id;
  final String emoji;
  final String name;
  final int type; // 0 现金 / 1 银行卡 / 2 信用卡 / 3 虚拟 / 4 AA挂账(M2)
  const PresetAccount(this.id, this.emoji, this.name, this.type);
}

const kPresetExpenseCategories = <PresetCategory>[
  PresetCategory('cat_food', '🍜', '餐饮', 0),
  PresetCategory('cat_shopping', '🛒', '购物', 0),
  PresetCategory('cat_daily', '🧴', '日用', 0),
  PresetCategory('cat_transport', '🚌', '交通', 0),
  PresetCategory('cat_housing', '🏠', '居住', 0),
  PresetCategory('cat_fun', '🎮', '娱乐', 0),
  PresetCategory('cat_medical', '💊', '医疗', 0),
  PresetCategory('cat_edu', '📚', '教育', 0),
  PresetCategory('cat_social', '🎁', '人情', 0),
  PresetCategory('cat_pet', '🐾', '宠物', 0),
  PresetCategory('cat_comm', '📱', '通讯', 0),
  PresetCategory('cat_other_exp', '📦', '其他', 0),
];

const kPresetIncomeCategories = <PresetCategory>[
  PresetCategory('inc_salary', '💰', '工资', 1),
  PresetCategory('inc_bonus', '🧧', '奖金', 1),
  PresetCategory('inc_invest', '📈', '理财', 1),
  PresetCategory('inc_refund', '↩️', '退款', 1),
  PresetCategory('inc_other', '✨', '其他', 1),
];

const kPresetAccounts = <PresetAccount>[
  PresetAccount('acc_cash', '💵', '现金', 0),
  PresetAccount('acc_wechat', '💚', '微信', 3),
  PresetAccount('acc_alipay', '💙', '支付宝', 3),
  PresetAccount('acc_bank', '🏦', '银行卡', 1),
];

/// AA 往来分类（kind=2 不计收支）：AA 垫付的挂账应收走这个分类，不进收支统计
const kAaMarkerCategoryId = 'cat_aa_marker';

/// AA 挂账虚拟账户 id（配对后自动创建，不计入总资产）
const kAaCreditAccountId = 'acc_aa_credit';

const kAccountEmojiChoices = <String>[
  '💵', '💚', '💙', '🏦', '💳', '🪙', '📈', '💰', '🐷', '🎒', '🏥', '🧾',
];

const kAccountTypeNames = <String>['现金', '银行卡', '信用卡', '虚拟账户', 'AA挂账'];
