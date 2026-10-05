import 'package:flutter/material.dart';

import '../theme.dart';
import 'aa_page.dart';
import 'bills_page.dart';
import 'edit_bill_page.dart';
import 'mine_page.dart';
import 'stats_page.dart';

/// 主框架：明细 / 图表 / [+ 记账] / AA / 我的
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  void _openEditor() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const EditBillPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          BillsPage(),
          StatsPage(),
          AaPage(),
          MinePage(),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: kPrimaryColor,
        foregroundColor: Colors.white,
        onPressed: _openEditor,
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        padding: EdgeInsets.zero,
        shape: const CircularNotchedRectangle(),
        child: Row(
          children: [
            Expanded(
                child: _navItem(0, Icons.receipt_long_outlined,
                    Icons.receipt_long, '明细')),
            Expanded(
                child: _navItem(1, Icons.pie_chart_outline, Icons.pie_chart, '图表')),
            const SizedBox(width: 64),
            Expanded(
                child: _navItem(
                    2, Icons.handshake_outlined, Icons.handshake, 'AA')),
            Expanded(
                child: _navItem(3, Icons.person_outline, Icons.person, '我的')),
          ],
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, IconData activeIcon, String label) {
    final selected = _index == i;
    final color = selected ? kPrimaryColor : Colors.grey.shade600;
    return InkWell(
      onTap: () => setState(() => _index = i),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected ? activeIcon : icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}
