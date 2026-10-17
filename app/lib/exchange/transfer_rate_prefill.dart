import 'package:flutter/foundation.dart';

import '../utils/currency.dart';
import 'exchange_rate_service.dart';

/// C-13 transfer prefill entry. Implementations hand out immutable
/// [RateQuote] snapshots so one prefill or adoption never mixes rates from
/// different moments, and late refreshes can only change future candidates.
abstract interface class TransferRatePrefill {
  /// True while the initial cache load or a network refresh is in flight.
  bool get loading;

  /// Current effective snapshot for the pair, or null when unavailable.
  RateQuote? quote(Currency base, Currency target);

  /// Loads the local cache once, then refreshes the network when the pair has
  /// no usable quote. Failures are recorded by the underlying service; the
  /// editor keeps working with manual amounts.
  Future<void> ensureFresh(Currency base, Currency target);

  void addListener(VoidCallback listener);

  void removeListener(VoidCallback listener);
}

/// Production adapter over the shared C-12 rate service.
class ExchangeRatePrefill implements TransferRatePrefill {
  ExchangeRatePrefill(this._service);

  final ExchangeRateService _service;

  @override
  bool get loading => _service.loading;

  @override
  RateQuote? quote(Currency base, Currency target) =>
      _service.quote(base, target);

  @override
  Future<void> ensureFresh(Currency base, Currency target) async {
    await _service.initialize();
    final quote = _service.quote(base, target);
    // A usable quote needs no request; manual overrides never expire.
    if (_service.loading ||
        (quote != null && (quote.isManual || !quote.isStale))) {
      return;
    }
    await _service.refresh();
  }

  @override
  void addListener(VoidCallback listener) => _service.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _service.removeListener(listener);
}
