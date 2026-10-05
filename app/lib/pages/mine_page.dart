import 'package:flutter/material.dart';

import '../theme.dart';
import 'accounts_page.dart';

/// 我的页：账户入口 + M2+ 功能占位 + 隐私说明
class MinePage extends StatelessWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context) {
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
