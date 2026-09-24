import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'calendar_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';

/// Top-level shell. The three destinations live in a drawer behind the menu
/// button at the top left of each of them, not in a bar along the bottom.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _shell = GlobalKey<ScaffoldState>();
  int _index = 0;

  late final List<Widget> _pages = [
    TasksScreen(onMenu: _openMenu),
    CalendarScreen(onMenu: _openMenu),
    SettingsScreen(onMenu: _openMenu),
  ];

  void _openMenu() => _shell.currentState?.openDrawer();

  /// Switch screens, refreshing the dated views so they stay correct across a
  /// midnight rollover or edits made from another one.
  void _select(int i) {
    Navigator.of(context).pop();
    if (i == _index) return;
    setState(() => _index = i);
    final provider = context.read<TaskProvider>();
    if (i == 0) provider.loadTasks();
    if (i == 1) provider.loadMonth(provider.month);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _shell,
      drawer: _Menu(index: _index, onSelected: _select),
      // Opened by the button alone. The calendar and its day list both page
      // sideways, and an edge-drag would take those swipes off them.
      drawerEnableOpenDragGesture: false,
      body: SafeArea(child: IndexedStack(index: _index, children: _pages)),
    );
  }
}

/// The drawer behind the menu button: the three screens, the current one
/// picked out.
class _Menu extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelected;

  const _Menu({required this.index, required this.onSelected});

  static const _items = [
    _TabItem(Icons.check_circle_outline, Icons.check_circle, 'Tasks'),
    _TabItem(Icons.calendar_month_outlined, Icons.calendar_month, 'Calendar'),
    _TabItem(Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final overdue = context.watch<TaskProvider>().overdue.length;

    return Drawer(
      backgroundColor: p.sidebar,
      width: 264,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Caldo',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Dates.longDay(DateTime.now()),
                    style: TextStyle(color: p.faint, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            const SizedBox(height: 8),
            for (var i = 0; i < _items.length; i++)
              _MenuItem(
                item: _items[i],
                selected: index == i,
                // The overdue backlog is what the dot on the button stands
                // for, so the menu says how much of it there is.
                badge: i == 0 && overdue > 0 ? overdue : null,
                accent: accent.color,
                onTap: () => onSelected(i),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final _TabItem item;
  final bool selected;
  final int? badge;
  final Color accent;
  final VoidCallback onTap;

  const _MenuItem({
    required this.item,
    required this.selected,
    required this.badge,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final color = selected ? accent : p.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Icon(
                  selected ? item.activeIcon : item.icon,
                  color: color,
                  size: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? p.text : p.muted,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.overdue.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        color: AppColors.overdue,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _TabItem(this.icon, this.activeIcon, this.label);
}
