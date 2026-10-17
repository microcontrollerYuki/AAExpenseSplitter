import 'dart:math';

import 'package:flutter/material.dart';

/// Returns a local month-start only on confirmation. The caller owns its state,
/// so future calendar/report filters can reuse this without sharing a provider.
Future<DateTime?> showYearMonthPicker({
  required BuildContext context,
  required DateTime initialMonth,
}) => showDialog<DateTime>(
  context: context,
  builder: (_) => YearMonthPickerDialog(initialMonth: initialMonth),
);

class YearMonthPickerDialog extends StatefulWidget {
  const YearMonthPickerDialog({super.key, required this.initialMonth});

  final DateTime initialMonth;

  @override
  State<YearMonthPickerDialog> createState() => _YearMonthPickerDialogState();
}

class _YearMonthPickerDialogState extends State<YearMonthPickerDialog> {
  late int _year = widget.initialMonth.year;
  late int _month = widget.initialMonth.month;
  // Include unusual historical dates instead of clamping the opening value.
  late final int _firstYear = min(1, _year);
  late final int _lastYear = max(9999, _year);
  bool _showYears = false;
  bool _closing = false;

  void _close(DateTime? result) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('选择年月', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Row(
                children: [
                  IconButton(
                    tooltip: '上一年',
                    onPressed: _year > _firstYear
                        ? () => setState(() => _year--)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: TextButton(
                      key: const ValueKey('month-picker-year'),
                      onPressed: () => setState(() => _showYears = !_showYears),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$_year年'),
                            Icon(
                              _showYears
                                  ? Icons.arrow_drop_up
                                  : Icons.arrow_drop_down,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '下一年',
                    onPressed: _year < _lastYear
                        ? () => setState(() => _year++)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SizedBox(
                  height: 264,
                  child: _showYears
                      ? LayoutBuilder(
                          builder: (context, constraints) {
                            final textSize = MediaQuery.textScalerOf(context)
                                .scale(16);
                            final columns = textSize > 26.4 ? 2 : 3;
                            final rowHeight = max(48.0, textSize + 24);
                            return _YearGrid(
                              key: ValueKey((
                                _year,
                                columns,
                                rowHeight,
                                constraints.maxHeight,
                              )),
                              firstYear: _firstYear,
                              lastYear: _lastYear,
                              selectedYear: _year,
                              columns: columns,
                              rowHeight: rowHeight,
                              viewportHeight: constraints.maxHeight,
                              onChanged: (year) => setState(() {
                                _year = year;
                                _showYears = false;
                              }),
                            );
                          },
                        )
                      : GridView.count(
                          primary: false,
                          padding: EdgeInsets.zero,
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          mainAxisExtent: 56,
                          children: [
                            for (var month = 1; month <= 12; month++)
                              Semantics(
                                selected: month == _month,
                                child: OutlinedButton(
                                  key: ValueKey('month-picker-month-$month'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    backgroundColor: month == _month
                                        ? colors.primaryContainer
                                        : null,
                                    foregroundColor: month == _month
                                        ? colors.onPrimaryContainer
                                        : null,
                                    side: BorderSide(
                                      color: month == _month
                                          ? colors.primary
                                          : colors.outlineVariant,
                                    ),
                                  ),
                                  onPressed: () =>
                                      setState(() => _month = month),
                                  child: Text('$month月'),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 12),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                overflowSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => _close(null),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    key: const ValueKey('month-picker-confirm'),
                    onPressed: () => _close(DateTime(_year, _month, 1)),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uses the same dimensions for layout and initial positioning, including large
/// text. Years are built lazily; the selected year starts in the visible center.
class _YearGrid extends StatefulWidget {
  const _YearGrid({
    super.key,
    required this.firstYear,
    required this.lastYear,
    required this.selectedYear,
    required this.columns,
    required this.rowHeight,
    required this.viewportHeight,
    required this.onChanged,
  });

  final int firstYear;
  final int lastYear;
  final int selectedYear;
  final int columns;
  final double rowHeight;
  final double viewportHeight;
  final ValueChanged<int> onChanged;

  @override
  State<_YearGrid> createState() => _YearGridState();
}

class _YearGridState extends State<_YearGrid> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    final count = widget.lastYear - widget.firstYear + 1;
    final rows = (count / widget.columns).ceil();
    final selectedRow =
        (widget.selectedYear - widget.firstYear) ~/ widget.columns;
    final maxOffset = max(0.0, rows * widget.rowHeight - widget.viewportHeight);
    final offset =
        selectedRow * widget.rowHeight -
        (widget.viewportHeight - widget.rowHeight) / 2;
    _controller = ScrollController(
      initialScrollOffset: offset.clamp(0.0, maxOffset),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GridView.builder(
      key: const ValueKey('month-picker-years'),
      controller: _controller,
      padding: EdgeInsets.zero,
      itemCount: widget.lastYear - widget.firstYear + 1,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.columns,
        mainAxisExtent: widget.rowHeight,
      ),
      itemBuilder: (context, index) {
        final year = widget.firstYear + index;
        final selected = year == widget.selectedYear;
        return Semantics(
          selected: selected,
          child: TextButton(
            key: ValueKey('month-picker-year-$year'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              backgroundColor: selected ? colors.primaryContainer : null,
              foregroundColor: selected ? colors.onPrimaryContainer : null,
              textStyle: const TextStyle(fontSize: 16),
            ),
            onPressed: () => widget.onChanged(year),
            child: Text('$year'),
          ),
        );
      },
    );
  }
}
