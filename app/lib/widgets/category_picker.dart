import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../theme.dart';

/// 当前选择不再适用时只回退到一级，不猜测二级。
String? categorySelection(List<Category> categories, int kind, String? id) {
  if (kind != 0 && kind != 1) return null;
  for (final c in categories) {
    if (c.id == id && c.kind == kind) return id;
  }
  final roots = CategoryHierarchy(categories).rootsOfKind(kind);
  return roots.isEmpty ? null : roots.first.id;
}

/// 手动记账与 OCR 共用：一级立即选中，二级是明确归属的可选细分。
class CategoryPicker extends StatefulWidget {
  const CategoryPicker({
    super.key,
    required this.categories,
    required this.kind,
    required this.selectedId,
    required this.onSelected,
    this.onManage,
  });

  final List<Category> categories;
  final int kind;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final VoidCallback? onManage;

  @override
  State<CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<CategoryPicker> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _selectRoot(String id) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    widget.onSelected(id);
  }

  @override
  Widget build(BuildContext context) {
    final tree = CategoryHierarchy(widget.categories);
    final id = categorySelection(
      widget.categories,
      widget.kind,
      widget.selectedId,
    );
    final root = tree.rootOf(id);
    final children = root == null ? <Category>[] : tree.childrenOf(root.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Tooltip(
            message: tree.pathOf(id),
            child: Text(
              '已选：${tree.pathOf(id)}',
              key: const ValueKey('category-selected-path'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: kPrimaryColor),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            children: [
              if (children.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  key: ValueKey('category-child-panel-${root!.id}'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kPrimaryColor.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${root.name} 的二级分类（可选）',
                        style: const TextStyle(fontSize: 12),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          ChoiceChip(
                            key: ValueKey('category-direct-${root.id}'),
                            label: const Text('直接使用一级'),
                            selected: id == root.id,
                            onSelected: (_) => widget.onSelected(root.id),
                          ),
                          for (final c in children)
                            ChoiceChip(
                              key: ValueKey('category-child-${c.id}'),
                              label: Text('${c.emoji} ${c.name}'),
                              selected: id == c.id,
                              onSelected: (_) => widget.onSelected(c.id),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('一级分类', style: TextStyle(fontSize: 12)),
              ),
              if (tree.rootsOfKind(widget.kind).isEmpty)
                const Text('暂无分类，可先到分类管理新增'),
              GridView(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  mainAxisExtent:
                      76 *
                      MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
                  mainAxisSpacing: 2,
                ),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final c in tree.rootsOfKind(widget.kind))
                    _RootCell(
                      key: ValueKey('category-root-${c.id}'),
                      emoji: c.emoji,
                      name: c.name,
                      selected: root?.id == c.id,
                      onTap: () => _selectRoot(c.id),
                    ),
                  if (widget.onManage != null)
                    _RootCell(
                      emoji: '⚙️',
                      name: '管理',
                      selected: false,
                      onTap: widget.onManage!,
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RootCell extends StatelessWidget {
  const _RootCell({
    super.key,
    required this.emoji,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: name,
    child: Semantics(
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 23,
              backgroundColor: selected
                  ? kPrimaryColor.withValues(alpha: 0.15)
                  : Colors.grey.shade100,
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(height: 4),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: selected ? kPrimaryColor : Colors.black87,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 确认后返回实际分类 ID；关闭窗口不改变调用方选择。
Future<String?> showCategoryPicker({
  required BuildContext context,
  required List<Category> categories,
  required int kind,
  required String? selectedId,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (sheetContext) =>
      _CategorySheet(categories: categories, kind: kind, initialId: selectedId),
);

class _CategorySheet extends StatefulWidget {
  const _CategorySheet({
    required this.categories,
    required this.kind,
    required this.initialId,
  });
  final List<Category> categories;
  final int kind;
  final String? initialId;
  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  late String? _id = categorySelection(
    widget.categories,
    widget.kind,
    widget.initialId,
  );
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: Column(
        children: [
          const Padding(padding: EdgeInsets.all(12), child: Text('选择分类')),
          Expanded(
            child: CategoryPicker(
              categories: widget.categories,
              kind: widget.kind,
              selectedId: _id,
              onSelected: (id) => setState(() => _id = id),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton(
              onPressed: _id == null ? null : () => Navigator.pop(context, _id),
              child: const Text('使用所选分类'),
            ),
          ),
        ],
      ),
    ),
  );
}
