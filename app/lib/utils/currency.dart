/// First supported ISO 4217 currencies. Minor units checked against SIX List One
/// on 2026-10-10. Use codes, not ambiguous symbols, to identify a currency.
enum Currency {
  cny('CNY', '人民币', 2),
  usd('USD', '美元', 2),
  hkd('HKD', '港币', 2),
  eur('EUR', '欧元', 2),
  jpy('JPY', '日元', 0),
  gbp('GBP', '英镑', 2);

  const Currency(this.code, this.displayName, this.minorUnitDigits);

  final String code;
  final String displayName;
  final int minorUnitDigits;

  /// Unknown or ambiguous values stay unknown; never default them to CNY.
  static Currency? tryFromCode(String code) {
    final normalized = code.trim().toUpperCase();
    for (final currency in values) {
      if (currency.code == normalized) return currency;
    }
    return null;
  }
}
