import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/category_hierarchy.dart';
import '../providers.dart';

enum _Destination { existing, create, uncategorized }

/// 删除范围采用完整快照；分类实时订阅仅用于选择和提示，不替换确认快照。
class CategoryDeleteDialog extends ConsumerStatefulWidget {
  const CategoryDeleteDialog({super.key, required this.preview});

  final CategoryDeletePreview preview;

  @override
  ConsumerState<CategoryDeleteDialog> createState() =>
      _CategoryDeleteDialogState();
}

class _CategoryDeleteDialogState extends ConsumerState<CategoryDeleteDialog> {
  late CategoryDeletePreview _preview = widget.preview;
  final _name = TextEditingController();
  _Destination? _destination;
  Category? _target;
  Category? _targetParent;
  Category? _newParent;
  String _emoji = '🏷️';
  String? _error;
  bool _wholeGroup = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final next = await ref
          .read(databaseProvider)
          .previewCategoryDeletion(_preview.sourceId);
      if (!mounted) return;
      setState(() {
        _preview = next;
        _wholeGroup = false;
        _target = null;
        _targetParent = null;
        _newParent = null;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is StateError ? e.message : '读取失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy || _destination == null) return;
    if (_destination == _Destination.create && _name.text.trim().isEmpty) {
      setState(() => _error = '请填写分类名称');
      return;
    }
    final destination = switch (_destination!) {
      _Destination.existing => CategoryDeleteDestination.existing(
        _target!,
        parent: _targetParent,
      ),
      _Destination.create => CategoryDeleteDestination.create(
        id: 'cat_${const Uuid().v4()}',
        name: _name.text,
        emoji: _emoji,
        parent: _newParent,
      ),
      _Destination.uncategorized =>
        const CategoryDeleteDestination.uncategorized(),
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(databaseProvider)
          .deleteCategoryAndReassign(
            expected: _preview,
            destination: destination,
            confirmWholeGroup: _wholeGroup,
          );
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(true);
      }
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
    final state = ref.watch(categoriesProvider);
    final all = state.value ?? const <Category>[];
    final byId = {for (final c in all) c.id: c};
    final tree = CategoryHierarchy(all);
    final source = _preview.categories.singleWhere(
      (c) => c.id == _preview.sourceId,
    );
    final deleting = _preview.categories.map((c) => c.id).toSet();
    final parents = tree
        .rootsOfKind(source.kind)
        .where((c) => c.parentId == null && !deleting.contains(c.id))
        .toList();
    final targets = <Category>[
      for (final parent in parents) ...[
        parent,
        ...tree.childrenOf(parent.id).where((c) => !deleting.contains(c.id)),
      ],
    ];
    final targetValid =
        _target != null &&
        targets.contains(_target) &&
        (_target!.parentId == null || byId[_target!.parentId] == _targetParent);
    final parentValid = _newParent == null || parents.contains(_newParent);
    final hasChildren = _preview.categories.length > 1;
    final canDelete =
        !_busy &&
        state.hasValue &&
        _destination != null &&
        (!hasChildren || _wholeGroup) &&
        (_destination != _Destination.existing || targetValid) &&
        (_destination != _Destination.create || parentValid);

    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: const Text('删除分类并转移账单'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('将删除：${source.name}'),
              if (hasChildren) ...[
                const SizedBox(height: 8),
                const Text('同时删除以下二级分类：'),
                for (final c in _preview.categories.where(
                  (c) => c.id != source.id,
                ))
                  Text('· ${c.name}'),
              ],
              const SizedBox(height: 12),
              Text(
                '活跃账单 ${_preview.activeBillCount} 笔 · 已删除账单 ${_preview.deletedBillCount} 笔',
              ),
              const Text('全部账单都会转移分类，金额和余额不变。已删除账单恢复后也使用新的分类。'),
              if (hasChildren)
                CheckboxListTile(
                  key: const ValueKey('category-delete-whole-group'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    '确认删除一级及全部 ${_preview.categories.length - 1} 个二级分类',
                  ),
                  subtitle: const Text('如需保留二级，请取消后先迁移二级。'),
                  value: _wholeGroup,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _wholeGroup = value ?? false),
                ),
              const SizedBox(height: 12),
              const Text('账单转移到'),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    _Destination.existing: '已有分类',
                    _Destination.create: '新增分类',
                    _Destination.uncategorized: '未分类',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: _destination == entry.key,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() {
                              _destination = entry.key;
                              _error = null;
                            }),
                    ),
                ],
              ),
              if (_destination == _Destination.existing) ...[
                KeyedSubtree(
                  key: const ValueKey('category-delete-target'),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(_target),
                    initialValue: _target?.id,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '目标分类'),
                    hint: const Text('请选择同类型分类'),
                    items: [
                      for (final c in targets)
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            tree.pathOf(c.id),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (_target != null &&
                          !targets.any((c) => c.id == _target!.id))
                        DropdownMenuItem(
                          value: _target!.id,
                          enabled: false,
                          child: const Text('目标分类已不可用'),
                        ),
                    ],
                    onChanged: _busy || !state.hasValue
                        ? null
                        : (id) => setState(() {
                            _target = byId[id];
                            _targetParent = byId[_target?.parentId];
                            _error = null;
                          }),
                  ),
                ),
                if (targets.isEmpty) const Text('暂无可用分类，可新增分类或转到未分类。'),
                if (_target != null && !targetValid)
                  const Text('目标分类已变化，请重新选择。'),
              ],
              if (_destination == _Destination.create) ...[
                KeyedSubtree(
                  key: const ValueKey('category-delete-new-parent'),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(_newParent),
                    initialValue: _newParent?.id ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '新分类所属一级'),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('一级分类（无父级）'),
                      ),
                      for (final c in parents)
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (_newParent != null &&
                          !parents.any((c) => c.id == _newParent!.id))
                        DropdownMenuItem(
                          value: _newParent!.id,
                          enabled: false,
                          child: const Text('目标一级已不可用'),
                        ),
                    ],
                    onChanged: _busy || !state.hasValue
                        ? null
                        : (id) => setState(() {
                            _newParent = byId[id];
                            _error = null;
                          }),
                  ),
                ),
                if (!parentValid) const Text('目标一级已变化，请重新选择。'),
                TextField(
                  key: const ValueKey('category-delete-new-name'),
                  controller: _name,
                  readOnly: _busy,
                  decoration: const InputDecoration(labelText: '新分类名称'),
                  onChanged: (_) => setState(() => _error = null),
                ),
                const SizedBox(height: 8),
                const Text('新分类图标'),
                Wrap(
                  spacing: 4,
                  children: [
                    for (final emoji in const [
                      '🏷️',
                      '🍜',
                      '🛒',
                      '☕',
                      '💰',
                      '🎁',
                      '📦',
                      '✨',
                    ])
                      ChoiceChip(
                        label: Text(emoji),
                        selected: _emoji == emoji,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _emoji = emoji),
                      ),
                  ],
                ),
              ],
              if (_destination == _Destination.uncategorized)
                const Text('转移后显示为“未分类”，之后可逐笔选择分类。'),
              if (state.hasError) const Text('分类读取失败，请关闭后重试。'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              TextButton(
                onPressed: _busy ? null : _refresh,
                child: const Text('刷新删除范围'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: canDelete ? _delete : null,
            child: const Text('确认转移并删除'),
          ),
        ],
      ),
    );
  }
}
