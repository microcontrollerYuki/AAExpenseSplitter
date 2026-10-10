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
  bool _positioned = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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
    final selected = widget.categories.where((c) => c.id == id).firstOrNull;
    final roots = tree.rootsOfKind(widget.kind);
    final children = root == null ? <Category>[] : tree.childrenOf(root.id);
    final rootIndex = roots.indexWhere((c) => c.id == root?.id);
    final count = roots.length + (widget.onManage == null ? 0 : 1);
    final rowHeight =
        86.0 + 28 * (MediaQuery.textScalerOf(context).scale(1) - 1).clamp(0, 2);
    // 编辑旧账时先露出所属行；后续点选和用户滚动保持当前位置。
    if (!_positioned && rootIndex >= 0) {
      _positioned = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(
            (rootIndex ~/ 5 * rowHeight).clamp(
              0.0,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
      });
    }
    return Material(
      color: Colors.white,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        children: [
          if (roots.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('暂无分类，可先到分类管理新增'),
            ),
          for (var row = 0; row < (count + 4) ~/ 5; row++) ...[
            SizedBox(
              key: ValueKey('category-root-row-$row'),
              height: rowHeight,
              child: Row(
                children: [
                  for (var col = 0; col < 5; col++)
                    Expanded(
                      child: row * 5 + col < roots.length
                          ? _CategoryCell(
                              key: ValueKey(
                                'category-root-${roots[row * 5 + col].id}',
                              ),
                              emoji: roots[row * 5 + col].emoji,
                              name:
                                  roots[row * 5 + col].id == root?.id &&
                                      selected?.id != root?.id
                                  ? '${roots[row * 5 + col].name}-${selected?.name ?? ''}'
                                  : roots[row * 5 + col].name,
                              path: roots[row * 5 + col].id == root?.id
                                  ? tree.pathOf(id)
                                  : tree.pathOf(roots[row * 5 + col].id),
                              selected: roots[row * 5 + col].id == root?.id,
                              hasChildren: tree
                                  .childrenOf(roots[row * 5 + col].id)
                                  .isNotEmpty,
                              onTap: () =>
                                  widget.onSelected(roots[row * 5 + col].id),
                            )
                          : row * 5 + col == roots.length &&
                                widget.onManage != null
                          ? _CategoryCell(
                              emoji: '⚙️',
                              name: '管理',
                              path: '分类管理',
                              selected: false,
                              onTap: widget.onManage!,
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ),
            if (children.isNotEmpty && rootIndex ~/ 5 == row)
              LayoutBuilder(
                builder: (context, constraints) => Stack(
                  key: ValueKey('category-child-panel-${root!.id}'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F5F7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: GridView(
                          shrinkWrap: true,
                          primary: false,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 5,
                                mainAxisExtent: rowHeight,
                              ),
                          children: [
                            for (final c in children)
                              _CategoryCell(
                                key: ValueKey('category-child-${c.id}'),
                                emoji: c.emoji,
                                name: c.name,
                                path: tree.pathOf(c.id),
                                selected: c.id == id,
                                onTap: () => widget.onSelected(c.id),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left:
                          constraints.maxWidth / 5 * (rootIndex % 5 + 0.5) - 8,
                      top: 0,
                      child: CustomPaint(
                        size: const Size(16, 8),
                        painter: _CategoryPointer(),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CategoryPointer extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFF4F5F7));
  }

  @override
  bool shouldRepaint(covariant _CategoryPointer oldDelegate) => false;
}

class _CategoryCell extends StatelessWidget {
  const _CategoryCell({
    super.key,
    required this.emoji,
    required this.name,
    required this.path,
    required this.selected,
    required this.onTap,
    this.hasChildren = false,
  });

  final String emoji;
  final String name;
  final String path;
  final bool selected;
  final VoidCallback onTap;
  final bool hasChildren;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: path,
    child: Semantics(
      label: path,
      selected: selected,
      button: true,
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected
                            ? kPrimaryColor.withValues(alpha: 0.09)
                            : Colors.transparent,
                      ),
                      alignment: Alignment.center,
                      child: Text(emoji, style: const TextStyle(fontSize: 27)),
                    ),
                    if (hasChildren)
                      Positioned(
                        right: -1,
                        bottom: 0,
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.more_horiz,
                            size: 13,
                            color: selected
                                ? kPrimaryColor
                                : Colors.blueGrey.shade300,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    color: selected ? kPrimaryColor : Colors.black87,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
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
