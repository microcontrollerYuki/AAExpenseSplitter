import 'app_database.dart';

/// 最多两级的只读视图。异常旧节点作为独立一级展示，不递归、不改库。
class CategoryHierarchy {
  CategoryHierarchy(Iterable<Category> categories)
      : _byId = {for (final c in categories) c.id: c};

  final Map<String, Category> _byId;

  Category? _validParent(Category category) {
    if (category.kind != 0 && category.kind != 1) return null;
    final parent = _byId[category.parentId];
    return parent != null && parent.id != category.id &&
            parent.kind == category.kind && parent.parentId == null
        ? parent
        : null;
  }

  List<Category> _sorted(Iterable<Category> categories) => categories.toList()
    ..sort((a, b) {
      final order = a.sort.compareTo(b.sort);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });

  List<Category> rootsOfKind(int kind) => _sorted(_byId.values.where(
      (c) => c.kind == kind && _validParent(c) == null));

  List<Category> childrenOf(String parentId) => _sorted(_byId.values.where(
      (c) => _validParent(c)?.id == parentId));

  Category? rootOf(String? id) {
    final category = _byId[id];
    return category == null ? null : _validParent(category) ?? category;
  }

  String pathOf(String? id) {
    final category = _byId[id];
    if (category == null) return '未分类';
    final parent = _validParent(category);
    return parent == null ? category.name : '${parent.name} / ${category.name}';
  }
}
