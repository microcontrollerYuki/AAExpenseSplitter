import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';
import 'accounts_page.dart';
import 'categories_page.dart';

/// 我的页：账户入口 + M2+ 功能占位 + 隐私说明 + 测试后门
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined,
                  color: kPrimaryColor),
              title: const Text('账户与资产'),
              subtitle: const Text('账户管理 · 期初余额 · 总资产'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AccountsPage())),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.category_outlined),
                  title: const Text('分类管理'),
                  subtitle: const Text('自定义分类 · 图标 · 排序'),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const CategoriesPage())),
                ),
                ListTile(
                  leading: const Icon(Icons.savings_outlined),
                  title: const Text('预算'),
                  subtitle: const Text('月总预算与分类预算'),
                  trailing: _m2Chip(),
                  onTap: () => _todo(context, '预算功能在后续版本提供'),
                ),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('数据导出'),
                  subtitle: const Text('导出 CSV / 加密备份'),
                  trailing: _m2Chip(),
                  onTap: () => _todo(context, '数据导出在后续版本提供'),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('回收站'),
                  subtitle: const Text('已删除账单保留 30 天'),
                  trailing: _m2Chip(),
                  onTap: () => _todo(context, '回收站在后续版本提供'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('隐私说明'),
                  subtitle: const Text('当前版本所有数据仅保存在本机数据库，不上传任何服务器'),
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('关于'),
                  subtitle: const Text('AA记账 M1 原型 v0.1.0'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 测试后门（设计图）：允许删除全部账单（含 AA 账单/分摊组/结算），用于测试
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.delete_forever, color: kExpenseColor),
              title: const Text('清空测试数据（后门）'),
              subtitle: const Text('删除全部账单与 AA 数据，保留账户/分类/配对'),
              onTap: () async {
                final ok1 = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('清空测试数据'),
                    content: const Text('将删除全部账单（含 AA 账单、分摊组、结算记录）。'
                        '账户、分类与配对信息保留。此操作不可恢复。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('继续')),
                    ],
                  ),
                );
                if (ok1 != true) return;
                if (!context.mounted) return;
                final ok2 = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('再次确认'),
                    content: const Text('真的要清空所有账单数据吗？'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('确认清空')),
                    ],
                  ),
                );
                if (ok2 != true) return;
                await ref.read(databaseProvider).deleteAllBillsAndAa();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已清空全部账单与 AA 数据')));
              },
            ),
          ),
        ],
      ),
    );
  }

  static Widget _m2Chip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text('M2',
          style: TextStyle(fontSize: 11, color: kPrimaryColor)),
    );
  }

  static void _todo(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }
}


