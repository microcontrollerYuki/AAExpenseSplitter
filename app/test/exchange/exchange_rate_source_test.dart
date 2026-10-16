import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate.dart';
import 'package:aa_expense_splitter/exchange/exchange_rate_source.dart';
import 'package:aa_expense_splitter/utils/currency.dart';

const _body = '''[
{"date":"2026-10-15","base":"EUR","quote":"CNY","rate":7.4993},
{"date":"2026-10-15","base":"EUR","quote":"GBP","rate":0.8461},
{"date":"2026-10-15","base":"EUR","quote":"HKD","rate":8.7953},
{"date":"2026-10-15","base":"EUR","quote":"JPY","rate":177.06},
{"date":"2026-10-15","base":"EUR","quote":"USD","rate":1.1208}]
''';

void main() {
  Future<(HttpServer, HttpRateSource)> serve(
    Future<void> Function(HttpRequest) handler, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await handler(request);
      } on SocketException {
        // Expected when a bounded request is aborted by the client.
      } on HttpException {
        // Expected when a bounded request is aborted by the client.
      }
    });
    final source = HttpRateSource(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/rates'),
      now: () => DateTime.utc(2026, 10, 16, 12),
      timeout: timeout,
    );
    addTearDown(() async {
      source.dispose();
      await server.close(force: true);
    });
    return (server, source);
  }

  test(
    'HTTP source preserves exact rates and accepts only a complete response',
    () async {
      final (_, source) = await serve((request) async {
        expect(
          request.headers.value(HttpHeaders.acceptHeader),
          'application/json',
        );
        request.response.write(_body);
        await request.response.close();
      });
      final result = await source.fetch();
      expect(result.rates[Currency.cny], RateRatio.parse('7.4993'));
      expect(
        result.ratio(Currency.usd, Currency.cny),
        RateRatio(BigInt.from(74993), BigInt.from(11208)),
      );
      await expectLater(source.fetch(), throwsStateError);
    },
  );

  test('redirect is rejected without following another endpoint', () async {
    var calls = 0;
    final (_, source) = await serve((request) async {
      calls++;
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/redirect');
      await request.response.close();
    });
    await expectLater(source.fetch(), throwsA(isA<HttpException>()));
    expect(calls, 1);
  });

  test('oversized streamed response is rejected before parsing', () async {
    final (_, source) = await serve((request) async {
      request.response.write(' ' * 32769);
      await request.response.close();
    });
    await expectLater(source.fetch(), throwsFormatException);
  });

  test('invalid UTF-8 cannot be treated as a valid quote', () async {
    final (_, source) = await serve((request) async {
      request.response.add([0xff, 0xfe]);
      await request.response.close();
    });
    await expectLater(source.fetch(), throwsFormatException);
  });

  test(
    'timeout bounds the whole request including a slow response body',
    () async {
      final arrived = Completer<void>();
      final release = Completer<void>();
      final (_, source) = await serve((request) async {
        arrived.complete();
        await release.future;
        await request.response.close();
      }, timeout: const Duration(milliseconds: 120));
      final result = expectLater(
        source.fetch(),
        throwsA(isA<TimeoutException>()),
      );
      await arrived.future;
      await result;
      release.complete();
    },
  );

  test('explicit cancellation aborts an in-flight request', () async {
    final arrived = Completer<void>();
    final release = Completer<void>();
    final (_, source) = await serve((request) async {
      arrived.complete();
      await release.future;
      await request.response.close();
    });
    final result = expectLater(
      source.fetch(),
      throwsA(
        anyOf(
          isA<SocketException>(),
          isA<HttpException>(),
          isA<RateCancelledException>(),
        ),
      ),
    );
    await arrived.future;
    source.cancel();
    await result;
    release.complete();
  });
}
