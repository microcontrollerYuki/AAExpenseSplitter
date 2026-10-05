import 'package:flutter/material.dart';

import '../theme.dart';

/// 记账页数字键盘（钱迹风格）：支持 +− 连算，长按 ⌫ 清空
/// 1 2 3 ⌫ / 4 5 6 − / 7 8 9 + / 再记 0 . 保存
class NumberPad extends StatelessWidget {
  const NumberPad({
    super.key,
    required this.onKey,
    required this.onBackspace,
    required this.onClear,
    required this.onSave,
    this.onSaveAndAgain,
  });

  /// 数字 / '.' / '+' / '-'
  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onSave;

  /// 「再记」：保存后留在当前页继续记（编辑已有账单时传 null 隐藏该功能）
  final VoidCallback? onSaveAndAgain;

  void _handle(String label) {
    switch (label) {
      case '⌫':
        onBackspace();
      case '−':
        onKey('-');
      case '再记':
        onSaveAndAgain?.call();
      case '保存':
        onSave();
      default:
        onKey(label);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget cell(String label) {
      final isSave = label == '保存';
      final disabled = label == '再记' && onSaveAndAgain == null;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Material(
            color: isSave
                ? kPrimaryColor
                : (disabled
                    ? Colors.grey.shade200
                    : Theme.of(context).colorScheme.surface),
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: disabled ? null : () => _handle(label),
              onLongPress: label == '⌫' ? onClear : null,
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 52,
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: isSave ? 17 : 21,
                      fontWeight: FontWeight.w600,
                      color: isSave
                          ? Colors.white
                          : (disabled ? Colors.grey.shade400 : Colors.black87),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: ['1', '2', '3', '⌫'].map(cell).toList()),
        Row(children: ['4', '5', '6', '−'].map(cell).toList()),
        Row(children: ['7', '8', '9', '+'].map(cell).toList()),
        Row(children: ['再记', '0', '.', '保存'].map(cell).toList()),
      ],
    );
  }
}
