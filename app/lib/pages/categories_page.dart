import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../providers.dart';
import '../theme.dart';

/// 分类管理页：按支出/收入/不计收支分组；新增、改名/换图标、上移置顶、删除（无账单关联才可删）
class CategoriesPage extends ConsumerWidget {
  const CategoriesPage({super.key});

  static const _kindTabs = <int, String>{0: '支出', 1: '收入', 2: '不计收支'};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories =
        ref.watch(categoriesProvider).value ?? const <Category>[];

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('分类管理'),
          bottom: TabBar(
            isScrollable: false,
            labelColor: kPrimaryColor,
            tabs: const [
              Tab(text: '支出'),
              Tab(text: '收入'),
              Tab(text: '不计收支'),
            ],
          ),
        ),
        floatingActionButton: Builder(
          // Builder 取 DefaultTabController 子树的 context，
          // 否则 FAB onPressed 里 of(context) 拿不到 TabController（页面 context 在其外层）
          builder: (bctx) => FloatingActionButton.extended(
            backgroundColor: kPrimaryColor,
            foregroundColor: Colors.white,
            onPressed: () => _openEdit(
                bctx, null, _currentKind(DefaultTabController.of(bctx).index)),
            icon: const Icon(Icons.add),
            label: const Text('新增分类'),
          ),
        ),
        body: TabBarView(
          children: [
            for (final kind in _kindTabs.keys)
              _KindList(categories: categories, kind: kind),
          ],
        ),
      ),
    );
  }

  int _currentKind(int tabIndex) => _kindTabs.keys.elementAt(tabIndex);

  void _openEdit(BuildContext context, Category? cat, int kind) {
    showDialog(
      context: context,
      builder: (_) => _CategoryEditDialog(category: cat, kind: kind),
    );
  }
}

class _KindList extends ConsumerWidget {
  const _KindList({required this.categories, required this.kind});

  final List<Category> categories;
  final int kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = categories.where((c) => c.kind == kind).toList();
    if (list.isEmpty) {
      return const Center(
          child: Text('暂无分类，点右下角新增',
              style: TextStyle(color: Colors.grey)));
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      onReorderItem: (oldI, newI) {
        final ids = [for (final c in list) c.id];
        final moved = ids.removeAt(oldI);
        ids.insert(newI, moved);
        ref.read(databaseProvider).reorderCategories(ids);
      },
      itemCount: list.length,
      itemBuilder: (_, i) {
        final c = list[i];
        return ListTile(
          key: ValueKey(c.id),
          leading: CircleAvatar(
            backgroundColor: Colors.grey.shade100,
            child: Text(c.emoji, style: const TextStyle(fontSize: 20)),
          ),
          title: Text(c.name),
          subtitle: c.isPreset ? const Text('预置', style: TextStyle(fontSize: 11)) : null,
          trailing: ReorderableDragStartListener(
            index: i,
            child: const Icon(Icons.drag_handle, color: Colors.grey),
          ),
          onTap: () => showDialog(
            context: context,
            builder: (_) => _CategoryEditDialog(category: c, kind: kind),
          ),
        );
      },
    );
  }
}

class _CategoryEditDialog extends ConsumerStatefulWidget {
  const _CategoryEditDialog({required this.category, required this.kind});

  final Category? category;
  final int kind;

  @override
  ConsumerState<_CategoryEditDialog> createState() =>
      _CategoryEditDialogState();
}

class _CategoryEditDialogState extends ConsumerState<_CategoryEditDialog> {
  late final TextEditingController _nameCtl;
  late String _emoji;

  static const _iconLib = <String>[
    '🍜', '🛒', '🧴', '🚌', '🏠', '🎮', '💊', '📚', '🎁', '🐾', '📱', '📦',
    '💰', '🧧', '📈', '↩️', '✨', '☕', '🍰', '🍺', '🚗', '✈️', '🚄', '⛽',
    '👶', '👩‍👦', '🧓', '💇', '🏥', '🦷', '🏃', '⚽', '🎵', '🎬', '🚬', '🧹',
    '💡', '🧰', '🪑', '👕', '👟', '💍', '🛠️', '🌾', '🐟', '🥬', '🍚', '🧂',
  ];

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.category?.name ?? '');
    _emoji = widget.category?.emoji ?? '🏷️';
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) return _snack('请填写分类名称');
    final db = ref.read(databaseProvider);
    final id =
        widget.category?.id ?? 'cat_${const Uuid().v4().substring(0, 8)}';
    try {
      await db.upsertCategory(
        id: id,
        name: name,
        emoji: _emoji,
        kind: widget.kind,
        sort: widget.category?.sort ?? 99,
        isPreset: false,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) _snack('保存失败：$e');
    }
  }

  Future<void> _delete() async {
    final c = widget.category;
    if (c == null) return;
    final db = ref.read(databaseProvider);
    final n = await db.billCountOfCategory(c.id);
    if (n > 0) {
      _snack('该分类已有 $n 笔账单，无法删除（可改名继续用）');
      return;
    }
    await db.deleteCategory(c.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.category == null ? '新增分类' : '编辑分类'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            const Text('图标', style: TextStyle(fontSize: 13, color: Colors.grey)),
            const SizedBox(height: 6),
            SizedBox(
              height: 190,
              child: GridView.count(
                crossAxisCount: 8,
                shrinkWrap: true,
                childAspectRatio: 1,
                children: [
                  for (final e in _iconLib)
                    GestureDetector(
                      onTap: () => setState(() => _emoji = e),
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: _emoji == e
                              ? kPrimaryColor.withValues(alpha: 0.18)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _emoji == e
                                  ? kPrimaryColor
                                  : Colors.transparent),
                        ),
                        child:
                            Center(child: Text(e, style: const TextStyle(fontSize: 20))),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.category != null)
          TextButton(
            onPressed: _delete,
            child: const Text('删除', style: TextStyle(color: kExpenseColor)),
          ),
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
