import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/category_delete_dialog.dart';

/// 支出 / 收入最多两级；一级拖动整个分组，二级只在自己的一级下排序。
class CategoriesPage extends ConsumerWidget {
  const CategoriesPage({super.key});

  static const _kindTabs = <int, String>{0: '支出', 1: '收入', 2: '不计收支'};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(categoriesProvider);
    final categories = state.value ?? const <Category>[];

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
            onPressed: state.hasValue
                ? () => _openEdit(
                    bctx,
                    null,
                    _currentKind(DefaultTabController.of(bctx).index),
                  )
                : null,
            icon: const Icon(Icons.add),
            label: const Text('新增分类'),
          ),
        ),
        body: state.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const Center(child: Text('分类读取失败，请稍后重试')),
          data: (_) => TabBarView(
            children: [
              for (final kind in _kindTabs.keys)
                _KindList(categories: categories, kind: kind),
            ],
          ),
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
    final tree = CategoryHierarchy(categories);
    final roots = tree.rootsOfKind(kind);
    final list = roots.where((c) => c.parentId == null).toList();
    final invalid = roots.where((c) => c.parentId != null).toList();
    if (roots.isEmpty) {
      return const Center(
        child: Text('暂无分类，点右下角新增', style: TextStyle(color: Colors.grey)),
      );
    }
    return ReorderableListView.builder(
      key: ValueKey('category-roots-$kind'),
      padding: const EdgeInsets.only(bottom: 88),
      header: const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          '长按右侧手柄可同级排序',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
      buildDefaultDragHandles: false,
      onReorderItem: (oldI, newI) => _reorder(context, ref, list, oldI, newI),
      footer: invalid.isEmpty
          ? null
          : Column(
              children: [
                const Divider(),
                for (final c in invalid)
                  _tile(context, c, invalidHierarchy: true),
              ],
            ),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final c = list[i];
        final children = tree.childrenOf(c.id);
        return Column(
          key: ValueKey(c.id),
          children: [
            _tile(context, c, index: i, isRoot: true),
            if (children.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: ReorderableListView.builder(
                  key: ValueKey('category-children-${c.id}'),
                  shrinkWrap: true,
                  primary: false,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  onReorderItem: (oldI, newI) =>
                      _reorder(context, ref, children, oldI, newI),
                  itemCount: children.length,
                  itemBuilder: (_, j) => _tile(
                    context,
                    children[j],
                    index: j,
                    canMove: !categories.any(
                      (c) => c.parentId == children[j].id,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _reorder(
    BuildContext context,
    WidgetRef ref,
    List<Category> siblings,
    int oldI,
    int newI,
  ) async {
    final ids = [for (final c in siblings) c.id];
    ids.insert(newI, ids.removeAt(oldI));
    try {
      await ref.read(databaseProvider).reorderCategories(ids);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is StateError ? e.message : '排序失败，请稍后重试')),
        );
      }
    }
  }

  Widget _tile(
    BuildContext context,
    Category c, {
    int? index,
    bool isRoot = false,
    bool invalidHierarchy = false,
    bool canMove = false,
  }) => ListTile(
    key: ValueKey('category-row-${c.id}'),
    leading: CircleAvatar(
      backgroundColor: Colors.grey.shade100,
      radius: isRoot ? 20 : 16,
      child: Text(c.emoji, style: const TextStyle(fontSize: 20)),
    ),
    title: Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      invalidHierarchy
          ? '分类归属异常'
          : isRoot
          ? (c.isPreset ? '一级分类 · 预置' : '一级分类')
          : '二级分类',
      style: const TextStyle(fontSize: 11),
    ),
    trailing: invalidHierarchy
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isRoot && kind != 2)
                IconButton(
                  key: ValueKey('category-add-child-${c.id}'),
                  tooltip: '在${c.name}下新增二级',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => _CategoryEditDialog(
                      category: null,
                      kind: kind,
                      initialParentId: c.id,
                    ),
                  ),
                ),
              if (canMove)
                IconButton(
                  key: ValueKey('category-move-${c.id}'),
                  tooltip: '迁移到其他一级',
                  icon: const Icon(Icons.drive_file_move_outline),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => _CategoryMoveDialog(
                      category: c,
                      currentPath: CategoryHierarchy(categories).pathOf(c.id),
                    ),
                  ),
                ),
              // 移动端长按手柄进入排序，普通滑动用于滚动。
              ReorderableDelayedDragStartListener(
                key: ValueKey('category-drag-${c.id}'),
                index: index!,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.drag_handle, color: Colors.grey),
                ),
              ),
            ],
          ),
    onTap: () => showDialog(
      context: context,
      builder: (_) => _CategoryEditDialog(
        category: c,
        kind: kind,
        invalidHierarchy: invalidHierarchy,
      ),
    ),
  );
}

class _CategoryMoveDialog extends ConsumerStatefulWidget {
  const _CategoryMoveDialog({
    required this.category,
    required this.currentPath,
  });

  final Category category;
  final String currentPath;

  @override
  ConsumerState<_CategoryMoveDialog> createState() =>
      _CategoryMoveDialogState();
}

class _CategoryMoveDialogState extends ConsumerState<_CategoryMoveDialog> {
  String? _targetId;
  String? _error;
  bool _busy = false;

  Future<void> _move() async {
    final target = _targetId;
    if (_busy || target == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 父级使用打开窗口时的快照，事务拒绝已被另一入口迁移的旧请求。
      await ref.read(databaseProvider).moveSubcategory(
        id: widget.category.id,
        expectedParentId: widget.category.parentId!,
        targetParentId: target,
      );
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : '迁移失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(categoriesProvider);
    final all = state.value ?? const <Category>[];
    final parents = CategoryHierarchy(all)
        .rootsOfKind(widget.category.kind)
        .where((c) => c.parentId == null && c.id != widget.category.parentId)
        .toList();
    final targetAvailable = parents.any((c) => c.id == _targetId);
    return AlertDialog(
      scrollable: true,
      title: const Text('迁移二级分类'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前分类：${widget.currentPath}'),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('category-move-parent'),
              initialValue: _targetId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '目标一级'),
              hint: const Text('请选择一级分类'),
              items: [
                for (final c in parents)
                  DropdownMenuItem(
                    value: c.id,
                    child: Text(
                      c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (_targetId != null && !targetAvailable)
                  DropdownMenuItem(
                    value: _targetId,
                    enabled: false,
                    child: const Text('目标一级已不可用'),
                  ),
              ],
              onChanged: _busy || !state.hasValue || parents.isEmpty
                  ? null
                  : (id) => setState(() {
                      _targetId = id;
                      _error = null;
                    }),
            ),
            const SizedBox(height: 12),
            Text(
              state.hasError
                  ? '分类读取失败，请关闭后重试'
                  : !state.hasValue
                  ? '正在读取分类'
                  : parents.isEmpty
                  ? '请先新增另一个同类型一级分类'
                  : '迁移后保留该分类下的全部账单，追加到目标一级的末尾。',
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || !state.hasValue || !targetAvailable ? null : _move,
          child: const Text('迁移'),
        ),
      ],
    );
  }
}

class _CategoryEditDialog extends ConsumerStatefulWidget {
  const _CategoryEditDialog({
    required this.category,
    required this.kind,
    this.initialParentId,
    this.invalidHierarchy = false,
  });

  final Category? category;
  final int kind;
  final String? initialParentId;
  final bool invalidHierarchy;

  @override
  ConsumerState<_CategoryEditDialog> createState() =>
      _CategoryEditDialogState();
}

class _CategoryEditDialogState extends ConsumerState<_CategoryEditDialog> {
  late final TextEditingController _nameCtl;
  late String _emoji;
  late String? _parentId;
  String? _error;
  bool _busy = false;

  static const _iconLib = <String>[
    '🍜',
    '🛒',
    '🧴',
    '🚌',
    '🏠',
    '🎮',
    '💊',
    '📚',
    '🎁',
    '🐾',
    '📱',
    '📦',
    '💰',
    '🧧',
    '📈',
    '↩️',
    '✨',
    '☕',
    '🍰',
    '🍺',
    '🚗',
    '✈️',
    '🚄',
    '⛽',
    '👶',
    '👩‍👦',
    '🧓',
    '💇',
    '🏥',
    '🦷',
    '🏃',
    '⚽',
    '🎵',
    '🎬',
    '🚬',
    '🧹',
    '💡',
    '🧰',
    '🪑',
    '👕',
    '👟',
    '💍',
    '🛠️',
    '🌾',
    '🐟',
    '🥬',
    '🍚',
    '🧂',
  ];

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.category?.name ?? '');
    _emoji = widget.category?.emoji ?? '🏷️';
    _parentId = widget.category?.parentId ?? widget.initialParentId;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  void _close() {
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _save() async {
    if (_busy || widget.invalidHierarchy) return;
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写分类名称');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final db = ref.read(databaseProvider);
    final id =
        widget.category?.id ?? 'cat_${const Uuid().v4().substring(0, 8)}';
    try {
      await db.transaction(() async {
        final all = await db.getAllCategories();
        final siblings = all.where(
          (c) => c.kind == widget.kind && c.parentId == _parentId,
        );
        final lastSort = siblings.fold<int>(
          -1,
          (value, c) => c.sort > value ? c.sort : value,
        );
        await db.upsertCategory(
          id: id,
          name: name,
          emoji: _emoji,
          kind: widget.kind,
          sort: widget.category?.sort ?? lastSort + 1,
          isPreset: widget.category?.isPreset ?? false,
          parentId: _parentId,
          expected: widget.category,
        );
      });
      _close();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : '保存失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = widget.category;
    if (c == null) return;
    final db = ref.read(databaseProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (c.kind == 0 || c.kind == 1) {
        final preview = await db.previewCategoryDeletion(c.id);
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        final deleted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => CategoryDeleteDialog(preview: preview),
        );
        if (deleted == true) _close();
        return;
      }
      final n = await db.billCountOfCategory(c.id);
      if (!mounted) return;
      if (n > 0) {
        throw StateError('该分类已有 $n 笔账单（含已删除），无法删除（可改名继续用）');
      }
      await db.deleteCategory(c.id);
      _close();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : '删除失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(categoriesProvider).value ?? const <Category>[];
    final parents = CategoryHierarchy(all)
        .rootsOfKind(widget.kind)
        .where((c) => c.parentId == null)
        .toList();
    final parent = all.where((c) => c.id == _parentId).firstOrNull;
    return AlertDialog(
      scrollable: true,
      title: Text(
        widget.category != null
            ? '编辑分类'
            : _parentId == null
            ? '新增分类'
            : '新增二级分类',
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.invalidHierarchy) const Text('分类归属异常，暂不可修改；请先检查分类归属'),
            if (widget.category == null && widget.kind != 2)
              DropdownButtonFormField<String>(
                initialValue: _parentId ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '所属一级'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('一级分类（无父级）')),
                  for (final c in parents)
                    DropdownMenuItem(
                      value: c.id,
                      child: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (_parentId != null &&
                      !parents.any((c) => c.id == _parentId))
                    DropdownMenuItem(
                      value: _parentId,
                      enabled: false,
                      child: const Text('父级已不可用'),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (id) => setState(() {
                        _parentId = id == '' ? null : id;
                        _error = null;
                      }),
              )
            else if (_parentId != null && !widget.invalidHierarchy)
              Text('所属一级：${parent?.name ?? '父级已不可用'}'),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtl,
              readOnly: _busy || widget.invalidHierarchy,
              decoration: const InputDecoration(labelText: '名称'),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              '图标',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
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
                      onTap: _busy || widget.invalidHierarchy
                          ? null
                          : () => setState(() => _emoji = e),
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
                                : Colors.transparent,
                          ),
                        ),
                        child: Center(
                          child: Text(e, style: const TextStyle(fontSize: 20)),
                        ),
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
            onPressed: _busy ? null : _delete,
            child: const Text('删除', style: TextStyle(color: kExpenseColor)),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || widget.invalidHierarchy ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
