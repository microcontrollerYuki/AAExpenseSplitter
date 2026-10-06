import 'package:flutter_test/flutter_test.dart';

import 'package:aa_expense_splitter/recognition/bill_ocr.dart';

void main() {
  group('parseBillLines 通用规则', () {
    test('空输入返回空结果且 note 为 null', () {
      final r = parseBillLines([]);
      expect(r.lines, isEmpty);
      expect(r.amounts, isEmpty);
      expect(r.merchantGuess, '');
      expect(r.noteSuggestion, isNull);
      expect(r.detectedDateMs, isNull);
      expect(r.accountHintLine, isNull);
      expect(r.source, 'generic');
    });

    test('¥/元 标记金额提取并降序去重', () {
      final r = parseBillLines(['合计 ¥88.80', '优惠 5元', '现金支付 ¥25']);
      // {88.80, 5, 25} 降序
      expect(r.amounts, [88.8, 25, 5]);
    });

    test('纯金额行（大字金额）被提取，全角负号规范化', () {
      final r = parseBillLines(['−6.33', '88.80', '¥99.99']);
      expect(r.amounts, [99.99, 88.8, 6.33]);
    });

    test('异常金额被过滤：0 与百万以上', () {
      final r = parseBillLines(['0.00', '¥0', '¥9999999.99', '1234567.00']);
      // '1234567.00' 7位整数+2位小数匹配纯金额行但 >=1000000 被滤
      expect(r.amounts, isEmpty);
    });

    test('同一金额来自不同来源只保留一个', () {
      final r = parseBillLines(['88.80', '合计 ¥88.80']);
      expect(r.amounts, [88.8]);
    });

    test('日期时间解析：横杠+时分秒', () {
      final r = parseBillLines(['支付时间 2026-10-04 10:43:41']);
      final expectMs = DateTime(2026, 10, 4, 10, 43, 41).millisecondsSinceEpoch;
      expect(r.detectedDateMs, expectMs);
    });

    test('日期时间解析：年月日汉字格式', () {
      final r = parseBillLines(['2026年10月04日 21:18:37']);
      final expectMs = DateTime(2026, 10, 4, 21, 18, 37).millisecondsSinceEpoch;
      expect(r.detectedDateMs, expectMs);
    });

    test('日期无时间部分时补零', () {
      final r = parseBillLines(['2026.10.3 出票']);
      final expectMs = DateTime(2026, 10, 3).millisecondsSinceEpoch;
      expect(r.detectedDateMs, expectMs);
    });

    test('仅有时分秒没有日期则不解析日期', () {
      final r = parseBillLines(['10:43']);
      expect(r.detectedDateMs, isNull);
    });

    test('付款方式行被捕获为账户提示（只取首行）', () {
      final r = parseBillLines(['付款方式 零钱', '支付方式(0) 招商银行']);
      expect(r.accountHintLine, '付款方式 零钱');
    });

    test('收款方式/扣款方式也命中', () {
      expect(parseBillLines(['收款方式 储蓄卡']).accountHintLine, '收款方式 储蓄卡');
      expect(parseBillLines(['扣款方式 余额']).accountHintLine, '扣款方式 余额');
    });
  });

  group('商户与路线启发', () {
    test('高频纯中文名优先作为商户猜测', () {
      final r = parseBillLines(['瑞幸咖啡', '厦门市思明区', '瑞幸咖啡', '订单号 9987']);
      expect(r.merchantGuess, '瑞幸咖啡');
      expect(r.noteSuggestion, contains('瑞幸咖啡'));
    });

    test('同频时纯中文行胜过带字母数字行', () {
      final r = parseBillLines(['瑞幸咖啡NO.1', '瑞幸咖啡', '订单号 1']);
      expect(r.merchantGuess, '瑞幸咖啡');
    });

    test('关键词行（时间/合计/订单等）不作为商户', () {
      final r = parseBillLines(['2026-10-04 10:43', '合计 ¥88.80', '拼多多']);
      expect(r.merchantGuess, '拼多多');
    });

    test('无合格候选时商户为空、note 为 null', () {
      final r = parseBillLines(['2026-10-04 10:43:41', '订单号 9987', '¥88.80']);
      expect(r.merchantGuess, '');
      expect(r.noteSuggestion, isNull);
    });

    test('路线行进入备注建议（→ 分隔）', () {
      final r = parseBillLines(['厦门地铁', '湖滨东路→莲坂', '-2.00']);
      expect(r.noteSuggestion, '厦门地铁 湖滨东路→莲坂');
    });

    test('长横线也作为路线分隔符', () {
      final r = parseBillLines(['中山公园—镇海路', '¥3.00']);
      expect(r.noteSuggestion, contains('中山公园—镇海路'));
    });

    test('含年份或超长行不算路线', () {
      final r = parseBillLines([
        '2026年度总结—计划事项超长路线名称超过二十四个字符',
        '湖滨东路—2026莲坂',
        '¥3.00',
      ]);
      expect(r.noteSuggestion, isNull);
    });
  });

  group('微信模板', () {
    test('锚定大字金额下一行的纯中文商户名', () {
      final r = parseBillLines([
        '微信支付',
        '支付成功',
        '-6.33',
        '拼多多',
        '当前状态 支付成功',
        '付款方式 零钱',
        '支付时间 2026-10-04 10:43:41',
      ]);
      expect(r.source, 'wechat');
      expect(r.merchantGuess, '拼多多');
      expect(r.amounts, [6.33]);
      expect(r.accountHintLine, '付款方式 零钱');
    });

    test('金额下一行不是纯中文时回退频次启发', () {
      final r = parseBillLines([
        '支付成功',
        '收单机构 财付通',
        '-6.33',
        '订单号123456',
        '全氏羊奶',
        '全氏羊奶',
      ]);
      expect(r.source, 'wechat');
      expect(r.merchantGuess, '全氏羊奶');
    });

    test('大字金额在最后一行时无下一行可锚定', () {
      final r = parseBillLines(['支付成功', '财付通', '-6.33']);
      expect(r.source, 'wechat');
      expect(r.amounts, [6.33]);
    });

    test('锚点行含界面词被拒绝时保留通用商户', () {
      final r = parseBillLines([
        '支付成功',
        '收单机构 财付通',
        '-6.33',
        '转账',
      ]);
      expect(r.source, 'wechat');
      expect(r.merchantGuess, isNot('转账'));
    });

    test('签名词不足两条不命中模板', () {
      final r = parseBillLines(['支付成功', '-6.33', '拼多多']);
      expect(r.source, 'generic');
    });
  });

  group('支付宝模板', () {
    test('账单详情命中，仅标记来源', () {
      final r = parseBillLines(['账单详情', '全氏羊奶', '全氏羊奶', '25.00 元']);
      expect(r.source, 'alipay');
      expect(r.merchantGuess, '全氏羊奶');
      expect(r.amounts, [25.0]);
    });

    test('查看扣款顺序也命中', () {
      expect(parseBillLines(['查看扣款顺序', '¥1.00']).source, 'alipay');
    });

    test('收款方全称也命中', () {
      expect(parseBillLines(['收款方全称', '¥1.00']).source, 'alipay');
    });
  });

  group('模板优先级', () {
    test('同时命中微信与支付宝时微信优先', () {
      final r = parseBillLines(['支付成功', '财付通', '账单详情', '-1.00']);
      expect(r.source, 'wechat');
    });
  });
}
