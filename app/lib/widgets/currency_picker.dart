import 'package:flutter/material.dart';

import '../utils/currency.dart';

Future<Currency?> showEntryCurrencyPicker(
  BuildContext context, {
  Currency? selected,
  bool cnyOnly = false,
}) => showModalBottomSheet<Currency>(
  context: context,
  builder: (sheetContext) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('选择币种', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          for (final currency in Currency.values)
            if (!cnyOnly || currency == Currency.cny)
              ListTile(
                title: Text('${currency.displayName} ${currency.code}'),
                trailing: selected == currency ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sheetContext, currency),
              ),
        ],
      ),
    ),
  ),
);
