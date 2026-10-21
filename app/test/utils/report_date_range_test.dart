// R-03 专项：自定义日期范围模型。覆盖首末日包含、起日零点到结束日次日
// 零点的左闭右开区间、结束早于开始拒绝、跨月 / 跨年与次日零点边界。
import 'package:aa_expense_splitter/data/app_database.dart';
import 'package:aa_expense_splitter/utils/report_filter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_support.dart';

void main() {
  int ms(int year, int month, int day, [int hour = 0, int minute = 0]) =>
      DateTime(year, month, day, hour, minute).millisecondsSinceEpoch;

  group('ReportDateRange', () {
    test('归一为零点，区间为起日零点到结束日次日零点', () {
      final range = ReportDateRange(
        start: DateTime(2026, 10, 15, 13, 40),
        end: DateTime(2026, 10, 18, 8, 5),
      );
      expect(range.period.startMs, ms(2026, 10, 15));
      // 结束日次日零点（左闭右开，结束日整天包含）
      expect(range.period.endMs, ms(2026, 10, 19));
    });

    test('结束早于开始拒绝', () {
      expect(
        () => ReportDateRange(
          start: DateTime(2026, 10, 18),
          end: DateTime(2026, 10, 17, 23),
        ),
        throwsArgumentError,
      );
    });

    test('同日起止即单日区间，含当天任意时刻，排除次日零点', () {
      final range = ReportDateRange(
        start: DateTime(2026, 10, 15),
        end: DateTime(2026, 10, 15),
      );
      expect(range.dayCount, 1);
      expect(range.period.contains(ms(2026, 10, 15, 0, 0)), isTrue);
      expect(range.period.contains(ms(2026, 10, 15, 23, 59)), isTrue);
      expect(range.period.contains(ms(2026, 10, 16)), isFalse);
    });

    test('跨月边界：首末日包含，前一日与结束日次日零点排除', () {
      final range = ReportDateRange(
        start: DateTime(2026, 1, 30),
        end: DateTime(2026, 3, 2),
      );
      expect(range.dayCount, 32); // 1/30-31 两天 + 2 月 28 天 + 3/1-2 两天
      expect(range.period.contains(ms(2026, 1, 30)), isTrue);
      expect(range.period.contains(ms(2026, 1, 29, 23, 59)), isFalse);
      expect(range.period.contains(ms(2026, 2, 15, 12)), isTrue);
      expect(range.period.contains(ms(2026, 3, 2, 23, 59)), isTrue);
      expect(range.period.contains(ms(2026, 3, 3)), isFalse);
    });

    test('跨年边界含次日零点', () {
      final range = ReportDateRange(
        start: DateTime(2025, 12, 30),
        end: DateTime(2026, 1, 2),
      );
      expect(range.period.startMs, ms(2025, 12, 30));
      expect(range.period.endMs, ms(2026, 1, 3)); // 1 月 2 日次日零点
      expect(range.period.contains(ms(2025, 12, 31, 23, 59)), isTrue);
      expect(range.period.contains(ms(2026, 1, 1)), isTrue);
      expect(range.period.contains(ms(2026, 1, 2, 12)), isTrue);
      expect(range.period.contains(ms(2025, 12, 29, 23, 59)), isFalse);
      expect(range.period.contains(ms(2026, 1, 3)), isFalse);
    });

    test('shiftDays 保持跨度并按日历日进位', () {
      final range = ReportDateRange(
        start: DateTime(2026, 10, 28),
        end: DateTime(2026, 11, 3),
      );
      expect(range.dayCount, 7);
      final next = range.shiftDays(7);
      expect(next.firstDay, DateTime(2026, 11, 4));
      expect(next.lastDay, DateTime(2026, 11, 10));
      expect(next.dayCount, 7);
      final prev = range.shiftDays(-7);
      expect(prev.firstDay, DateTime(2026, 10, 21));
      expect(prev.lastDay, DateTime(2026, 10, 27));
    });

    test('相等性按首末日比较，供状态去重', () {
      final a = ReportDateRange(
        start: DateTime(2026, 10, 1, 9),
        end: DateTime(2026, 10, 15, 20),
      );
      final b = ReportDateRange(
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 15),
      );
      final c = ReportDateRange(
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 16),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });

  group('filterReportBills 与自定义范围', () {
    final categories = <Category>[];
    Bill bill(String id, int dateMs, {int type = 0, int amount = 100}) =>
        mkBill(id, type: type, amount: amount, dateMs: dateMs);

    test('跨年选集：只取范围内的账单', () {
      final bills = [
        bill('before', ms(2025, 12, 29, 23, 59)),
        bill('day1', ms(2025, 12, 30, 0, 0)),
        bill('eve', ms(2025, 12, 31, 23, 59)),
        bill('newyear', ms(2026, 1, 1, 8)),
        bill('lastday', ms(2026, 1, 2, 21)),
        bill('midnight', ms(2026, 1, 3, 0, 0)), // 结束日次日零点排除
      ];
      final selected = filterReportBills(
        bills: bills,
        categories: categories,
        filter: ReportFilter(
          period: ReportDateRange(
            start: DateTime(2025, 12, 30),
            end: DateTime(2026, 1, 2),
          ).period,
        ),
      );
      expect(selected.map((b) => b.id), ['lastday', 'newyear', 'eve', 'day1']);
    });
  });
}
