import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../utils/currency.dart';
import '../utils/money.dart';

/// 精确金额及其局部币种线索。没有明确币种时交由用户确认，不根据平台猜测。
class OcrMoneyCandidate {
  const OcrMoneyCandidate({required this.amountText, this.currency});

  final String amountText;
  final Currency? currency;

  bool get requiresCurrencyConfirmation => currency == null;

  @override
  bool operator ==(Object other) =>
      other is OcrMoneyCandidate &&
      other.amountText == amountText &&
      other.currency == currency;

  @override
  int get hashCode => Object.hash(amountText, currency);
}

/// 账单图片识别结果（本地中文 OCR + 规则解析）
class BillOcrResult {
  const BillOcrResult({
    required this.lines,
    required this.amounts,
    required this.merchantGuess,
    this.noteSuggestion,
    this.detectedDateMs,
    this.accountHintLine,
    this.source = 'generic',
  });

  /// 识别出的全部文本行
  final List<String> lines;

  /// 精确金额候选（按数值降序，同币种去重；币种不明时须由用户确认）
  final List<OcrMoneyCandidate> amounts;

  /// 商户/地点猜测
  final String merchantGuess;

  /// 备注建议：商户 + 路线/区间（如「厦门地铁 湖滨东路→莲坂」）
  final String? noteSuggestion;

  /// 从「支付时间/付款时间」等行解析出的日期时间
  final int? detectedDateMs;

  /// 「付款方式 xxx」原文行，用于匹配本地账户
  final String? accountHintLine;

  /// 识别来源：平台模板名（wechat / alipay …）或 generic
  final String source;
}

/// 识别账单图片：ML Kit 中文本地识别（无需联网，图片不出设备）
Future<BillOcrResult> recognizeBill(String imagePath) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
  try {
    final inputImage = InputImage.fromFilePath(imagePath);
    final recognized = await recognizer.processImage(inputImage);
    final lines = <String>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final t = line.text.trim();
        if (t.isNotEmpty) lines.add(t);
      }
    }
    return parseBillLines(lines);
  } finally {
    await recognizer.close();
  }
}

/// 解析入口：平台模板优先，通用规则兜底。
/// 平台账单（微信/支付宝…）版式固定，由模板做针对性提取；
/// 提取不到的字段保留通用解析结果；未命中任何模板（纸质小票等）走通用规则。
BillOcrResult parseBillLines(List<String> lines) {
  final base = _parseGeneric(lines);
  for (final t in _templates) {
    if (t.matches(lines)) {
      return t.refine(base, lines);
    }
  }
  return base;
}

final _templates = <BillTemplate>[_WechatBillTemplate(), _AlipayBillTemplate()];

// ---------------------------------------------------------------------------
// 平台模板
// ---------------------------------------------------------------------------

/// 平台账单模板：锚定字段标签与结构特征（而非行号），版式微调不致失效
abstract class BillTemplate {
  String get name;

  /// 签名词命中即认为属于该平台
  bool matches(List<String> lines);

  /// 在通用解析结果之上做平台化修正
  BillOcrResult refine(BillOcrResult base, List<String> lines);
}

/// 微信支付账单：大字金额行的下一行即商户名（如「-6.33」下方「拼多多」）
class _WechatBillTemplate implements BillTemplate {
  @override
  String get name => 'wechat';

  @override
  bool matches(List<String> lines) {
    var hits = 0;
    for (final l in lines) {
      if (l.contains('支付成功') ||
          l.contains('收单机构') ||
          l.contains('财付通') ||
          l.contains('当前状态')) {
        hits++;
      }
    }
    return hits >= 2;
  }

  @override
  BillOcrResult refine(BillOcrResult base, List<String> lines) {
    final idx = _bareAmountLineIndex(lines);
    if (idx >= 0 && idx + 1 < lines.length) {
      final cand = lines[idx + 1].trim();
      // OCR 行切分偶有波动：锚点候选必须是纯中文商户名，否则退回通用频次启发
      final pureCjk = RegExp(r'^[\u4e00-\u9fa5]{2,20}$').hasMatch(cand);
      if (pureCjk && _looksLikeMerchant(cand)) {
        return _rebuild(base, merchantOverride: cand, source: name);
      }
    }
    return _rebuild(base, source: name);
  }
}

/// 支付宝账单：通用解析已正确（商户名靠频次启发命中），仅标记来源
class _AlipayBillTemplate implements BillTemplate {
  @override
  String get name => 'alipay';

  @override
  bool matches(List<String> lines) {
    for (final l in lines) {
      if (l.contains('账单详情') || l.contains('查看扣款顺序') || l.contains('收款方全称')) {
        return true;
      }
    }
    return false;
  }

  @override
  BillOcrResult refine(BillOcrResult base, List<String> lines) =>
      _rebuild(base, source: name);
}

// ---------------------------------------------------------------------------
// 共享工具
// ---------------------------------------------------------------------------

int _bareAmountLineIndex(List<String> lines) {
  for (var i = 0; i < lines.length; i++) {
    final t = _normalizeAmountLine(lines[i]);
    if (RegExp(r'^[¥]?-?\d{1,7}\.\d{1,2}$').hasMatch(t)) return i;
  }
  return -1;
}

String _normalizeAmountLine(String line) => line
    .replaceAll(' ', '')
    .replaceAll('￥', '¥')
    .replaceAll('−', '-')
    .replaceAll('–', '-')
    .replaceAll('—', '-');

const _merchantKw =
    r'20\d{2}|\d{1,2}:\d{2}|订单|单号|编号|时间|电话|地址|合计|小票|欢迎|'
    r'微信|支付宝|财付通|收款|付款|总额|金额|¥|￥|积分|账单|详情|全部|更多|'
    r'解读|客服|管理|返回|交易|成功|失败|扣费|储蓄卡|借记卡|银行卡|支付|'
    r'小程序|喜欢|状态|服务|机构|商品|余额|零钱|红包|转账|充值|提现';

bool _looksLikeMerchant(String s) {
  if (s.length < 2 || s.length > 20) return false;
  if (RegExp(_merchantKw).hasMatch(s)) return false;
  return RegExp(r'[\u4e00-\u9fa5]').hasMatch(s);
}

String _findRoute(List<String> lines) {
  for (final line in lines) {
    if ((line.contains('→') || line.contains('—')) &&
        RegExp(r'[\u4e00-\u9fa5]').hasMatch(line) &&
        !RegExp(r'20\d{2}').hasMatch(line) &&
        line.length <= 24) {
      return line.replaceAll(' ', '');
    }
  }
  return '';
}

BillOcrResult _rebuild(
  BillOcrResult base, {
  String? merchantOverride,
  String? source,
}) {
  final merchant = merchantOverride ?? base.merchantGuess;
  final route = _findRoute(base.lines);
  final note = [
    if (merchant.isNotEmpty) merchant,
    if (route.isNotEmpty) route,
  ].join(' ');
  return BillOcrResult(
    lines: base.lines,
    amounts: base.amounts,
    merchantGuess: merchant,
    noteSuggestion: note.isEmpty ? null : note,
    detectedDateMs: base.detectedDateMs,
    accountHintLine: base.accountHintLine,
    source: source ?? base.source,
  );
}

// ---------------------------------------------------------------------------
// 通用规则解析（兜底 + 各字段基础提取）
// ---------------------------------------------------------------------------

const _maxMoneyLines = 2000;
const _maxMoneyLineLength = 1024;
const _maxMoneyCandidates = 128;
const _moneyToken = r'[+-]?(?:[0-9][0-9.,]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?';
const _explicitCurrencyToken =
    r'HK\$|US\$|CNY|RMB|USD|HKD|EUR|JPY|GBP|人民币|'
    r'美元|美金|港币|港元|欧元|日元|日币|英镑';
const _currencyToken =
    '(?:$_explicitCurrencyToken)'
    r'(?:\s*[¥￥$€£])?|[¥￥$€£]|元';
final _explicitMarker = RegExp(
  '^($_explicitCurrencyToken)(?:\\s*([¥￥\$€£]))?\$',
  caseSensitive: false,
);
final _markedMoney = RegExp(
  '($_currencyToken)\\s*($_moneyToken)|'
  '($_moneyToken)\\s*($_currencyToken)',
  caseSensitive: false,
);
final _bareMoney = RegExp('^($_moneyToken)\$');
final _amountNoise = RegExp(r'订单|单号|编号|流水号|交易号|电话|手机号|日期|时间');
final _overlongMoneyToken = RegExp(r'[0-9.,]{64}');

Currency? _currencyForMarker(String marker) {
  if (marker == '€') return Currency.eur;
  if (marker == '£') return Currency.gbp;
  final match = _explicitMarker.firstMatch(marker);
  if (match == null) return null;
  final currency = switch (match.group(1)!.toUpperCase()) {
    'CNY' || 'RMB' || '人民币' => Currency.cny,
    'USD' || r'US$' || '美元' || '美金' => Currency.usd,
    'HKD' || r'HK$' || '港币' || '港元' => Currency.hkd,
    'EUR' || '欧元' => Currency.eur,
    'JPY' || '日元' || '日币' => Currency.jpy,
    'GBP' || '英镑' => Currency.gbp,
    _ => null,
  };
  final symbol = match.group(2);
  if (symbol == null) return currency;
  // 仅同一金额前的兼容组合提供明确线索；USD € 等矛盾标记留待用户确认。
  final compatible = switch (currency) {
    Currency.cny || Currency.jpy => symbol == '¥' || symbol == '￥',
    Currency.usd || Currency.hkd => symbol == r'$',
    Currency.eur => symbol == '€',
    Currency.gbp => symbol == '£',
    null => false,
  };
  return compatible ? currency : null;
}

bool _hasMoneyBoundary(String line, int start, int end) {
  // 不把订单中的字母数字、额外小数或分组逗号截成另一个合法金额。
  final invalidNeighbor = RegExp(r'[A-Za-z0-9.,]');
  return (start == 0 || !invalidNeighbor.hasMatch(line[start - 1])) &&
      (end == line.length || !invalidNeighbor.hasMatch(line[end]));
}

List<OcrMoneyCandidate> _parseMoneyCandidates(List<String> lines) {
  final candidates = <OcrMoneyCandidate>{};

  void add(String numericText, Currency? currency) {
    // 未明确币种的候选最多允许两位小数，只作精确文本规范化；不会据此认定人民币。
    final precision = currency ?? Currency.cny;
    final units = parseMoneyToMinorUnits(numericText, precision);
    if (units == null || units == 0) return;
    // 图片中的负号常表示扣款，收支方向仍由记账表单确认。
    // 最小 int64 的绝对值无法作为正金额保存。
    final magnitude = BigInt.from(units).abs();
    if (magnitude > BigInt.parse('9223372036854775807')) return;
    candidates.add(
      OcrMoneyCandidate(
        amountText: formatMinorUnits(
          magnitude.toInt(),
          precision,
          grouping: false,
        ),
        currency: currency,
      ),
    );
  }

  for (final original in lines.take(_maxMoneyLines)) {
    if (candidates.length >= _maxMoneyCandidates) break;
    // 过长行整行跳过，不能截断后将小数前两位误当成金额。
    if (original.length > _maxMoneyLineLength ||
        _overlongMoneyToken.hasMatch(original) ||
        _amountNoise.hasMatch(original)) {
      continue;
    }
    final line = original
        .replaceAll('−', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-');
    var hasMarker = false;
    for (final match in _markedMoney.allMatches(line)) {
      hasMarker = true;
      if (!_hasMoneyBoundary(line, match.start, match.end)) continue;
      final marker = match.group(1) ?? match.group(4)!;
      final numeric = match.group(2) ?? match.group(3)!;
      add(numeric, _currencyForMarker(marker));
      if (candidates.length >= _maxMoneyCandidates) break;
    }
    // 有币种标记的非法金额不能再退回无币种候选（例如 JPY 1.00）。
    if (!hasMarker) {
      final numeric = line.trim();
      if (_bareMoney.hasMatch(numeric)) add(numeric, null);
    }
  }

  BigInt comparisonValue(OcrMoneyCandidate candidate) => BigInt.parse(
    candidate.currency == Currency.jpy
        ? '${candidate.amountText}00'
        : candidate.amountText.replaceAll('.', ''),
  );
  return candidates.toList()
    ..sort((a, b) => comparisonValue(b).compareTo(comparisonValue(a)));
}

/// 规则解析：明确币种与金额只在局部关联；含糊标记和裸金额等待用户确认。
BillOcrResult _parseGeneric(List<String> lines) {
  final amounts = _parseMoneyCandidates(lines);

  // 日期时间（优先「支付时间」行）：2026-10-04 10:43:41 / 2026年10月04日 21:18:37
  DateTime? date;
  for (final line in lines) {
    final m = RegExp(
      r'(20\d{2})[-/年.](\d{1,2})[-/月.](\d{1,2})[日号]?\s*'
      r'(?:(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
    ).firstMatch(line);
    if (m != null) {
      date = DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        m.group(4) != null ? int.parse(m.group(4)!) : 0,
        m.group(5) != null ? int.parse(m.group(5)!) : 0,
        m.group(6) != null ? int.parse(m.group(6)!) : 0,
      );
      break;
    }
  }

  // 付款方式行（用于账户匹配）
  String? accountHint;
  for (final line in lines) {
    if (RegExp('付款方式|支付方式|收款方式|扣款方式').hasMatch(line)) {
      accountHint = line;
      break;
    }
  }

  // 商户猜测：在合格短行（含中文、非界面词/关键词）中，
  // 优先「出现次数最多的纯中文行」——支付账单里商户名通常重复出现（顶部+金额下方），
  // 可避开状态栏时间、按钮文字等一次性干扰行；平票时取最早出现的一条
  final cands = <String>[];
  for (final line in lines) {
    if (line.length < 2 || line.length > 20) continue;
    if (RegExp(_merchantKw).hasMatch(line)) continue;
    if (_markedMoney.hasMatch(line)) continue;
    if (!RegExp(r'[\u4e00-\u9fa5]').hasMatch(line)) continue;
    cands.add(line);
  }
  var merchant = '';
  if (cands.isNotEmpty) {
    var bestScore = -1;
    for (final c in cands) {
      final freq = cands.where((x) => x == c).length;
      final pureCjk = !RegExp(r'[0-9A-Za-z]').hasMatch(c) ? 1 : 0;
      final score = freq * 10 + pureCjk * 5;
      if (score > bestScore) {
        bestScore = score;
        merchant = c;
      }
    }
  }

  final route = _findRoute(lines);
  final note = [
    if (merchant.isNotEmpty) merchant,
    if (route.isNotEmpty) route,
  ].join(' ');

  return BillOcrResult(
    lines: lines,
    amounts: amounts,
    merchantGuess: merchant,
    noteSuggestion: note.isEmpty ? null : note,
    detectedDateMs: date?.millisecondsSinceEpoch,
    accountHintLine: accountHint,
  );
}
