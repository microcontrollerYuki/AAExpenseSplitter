import '../data/app_database.dart';
import '../exchange/exchange_rate_service.dart';
import 'currency.dart';

/// One synchronous capture of every →CNY quote used by a conversion pass.
///
/// [ExchangeRateService.quote] is synchronous, so reading all pairs inside a
/// single function cannot interleave with a cache commit; the frozen set is
/// the one consistent snapshot for the whole pass. Downstream partitions
/// (summary, categories, trend, details, calendar) must reuse the same
/// per-bill values from [convertReportBillsToCny], never re-quote.
class FrozenCnyQuotes {
  FrozenCnyQuotes._(this._quotes);

  final Map<Currency, RateQuote> _quotes;

  /// Captures the →CNY quote of every supported currency through [lookup]
  /// (production passes the shared service's `quote`, tests inject fakes).
  /// A missing pair stays missing: those bills land in the excluded list of
  /// [convert] instead of failing the whole pass.
  static FrozenCnyQuotes capture(
    RateQuote? Function(Currency base, Currency target) lookup,
  ) {
    final quotes = <Currency, RateQuote>{};
    for (final currency in Currency.values) {
      final quote = lookup(currency, Currency.cny);
      if (quote != null) quotes[currency] = quote;
    }
    return FrozenCnyQuotes._(quotes);
  }

  /// Frozen quote toward CNY, or null when the pair had no usable rate at
  /// capture time (offline without cache and no manual override).
  RateQuote? quoteFor(Currency base) => _quotes[base];

  /// Any non-manual frozen quote is expired; display layers must say so and
  /// may still use the values (original-currency views stay available).
  bool get hasStale => _quotes.values
      .where((quote) => !quote.isManual)
      .any((quote) => quote.isStale);

  /// True only when at least one pair is frozen and every one is a manual
  /// override; an empty capture (no rates at all) is not "all manual".
  bool get allManual =>
      _quotes.isNotEmpty &&
      _quotes.values.every((quote) => quote.isManual);
}

/// One currency that could not be included in a CNY conversion pass.
class CnyExcludedCurrency {
  const CnyExcludedCurrency({
    required this.code,
    required this.count,
    required this.originalMinor,
  });

  /// Exact stored currency code; unknown historical codes stay verbatim.
  final String code;
  final int count;

  /// Original-currency minor-unit sum of the excluded bills.
  final BigInt originalMinor;
}

/// Per-bill CNY values for one immutable R-01 selection. Each bill is
/// converted exactly once with a single half-away-from-zero rounding; every
/// partition built from [valueFor] conserves the grand total by construction.
/// The model is read-only over the bill rows and never touches balances.
class CnyConvertedBills {
  CnyConvertedBills._(this._values, List<CnyExcludedCurrency> excluded, this.quotes)
    : valuesView = Map.unmodifiable(_values),
      excludedView = List.unmodifiable(excluded);

  final Map<String, BigInt> _values;
  final Map<String, BigInt> valuesView;
  final List<CnyExcludedCurrency> excludedView;
  final FrozenCnyQuotes quotes;

  /// Unmodifiable bill-id → CNY minor units for every converted bill.
  /// Partitions must read through [valueFor] / [sumFor], never re-convert.
  Map<String, BigInt> get values => valuesView;

  /// True when every selected bill was converted; partial results must be
  /// labelled as such and never presented as the complete total.
  bool get complete => excludedView.isEmpty;

  /// CNY minor units of one converted bill. Unknown ids return null so a
  /// stale bill list cannot silently read a neighbouring value. Bills with
  /// the same id but different content are not validated: callers must pass
  /// rows from the same selection instance the conversion consumed.
  BigInt? valueFor(Bill bill) => _values[bill.id];

  /// Exact BigInt sum over any subset of the original selection (a category
  /// partition, a month, one type). No re-rounding happens here. Each id is
  /// counted once per occurrence; selections never contain duplicate ids.
  BigInt sumFor(Iterable<Bill> bills) => bills.fold(
    BigInt.zero,
    (sum, bill) => sum + (_values[bill.id] ?? BigInt.zero),
  );

  /// Converts one R-01 selection with one frozen quote set. Bills whose
  /// currency is unsupported or has no frozen quote are listed in [excluded]
  /// with their count and original-currency sum, keeping the input order.
  /// Excluded entries merge by recognized (normalized) currency code;
  /// unrecognized codes stay verbatim.
  static CnyConvertedBills convert({
    required Iterable<Bill> bills,
    required FrozenCnyQuotes quotes,
  }) {
    final values = <String, BigInt>{};
    final excludedIndex = <String, CnyExcludedCurrency>{};
    for (final bill in bills) {
      final currency = Currency.tryFromCode(bill.currency);
      final quote = currency == null ? null : quotes._quotes[currency];
      if (quote == null) {
        final key = currency?.code ?? bill.currency;
        final previous = excludedIndex[key];
        excludedIndex[key] = CnyExcludedCurrency(
          code: key,
          count: (previous?.count ?? 0) + 1,
          originalMinor:
              (previous?.originalMinor ?? BigInt.zero) +
              BigInt.from(bill.amount),
        );
        continue;
      }
      values[bill.id] = quote.ratio.convertMinorUnits(
        BigInt.from(bill.amount),
        currency!,
        Currency.cny,
      );
    }
    return CnyConvertedBills._(values, excludedIndex.values.toList(), quotes);
  }
}
