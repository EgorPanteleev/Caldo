import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import '../utils/dates.dart';
import 'calendar_screen.dart';
import 'settings_screen.dart';
import 'tasks_screen.dart';

/// Width the menu takes, and so how far the screen slides over to show it.
const _menuWidth = 244.0;

/// Top-level shell. The three destinations live in a menu at the top left of
/// each of them, not in a bar along the bottom.
///
/// Opening it slides the whole screen to the right rather than laying a panel
/// over it: the screen is not covered up, it has moved aside, and what is on
/// it stays legible while the menu is open.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _menu = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 220),
  );

  late final Animation<double> _slide = CurvedAnimation(
    parent: _menu,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  int _index = 0;

  late final List<Widget> _pages = [
    TasksScreen(onMenu: _openMenu),
    CalendarScreen(onMenu: _openMenu),
    SettingsScreen(onMenu: _openMenu),
  ];

  bool get _isOpen => _menu.value > 0.5;

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  void _openMenu() => _menu.forward();
  void _closeMenu() => _menu.reverse();

  /// Switch screens, refreshing the dated views so they stay correct across a
  /// midnight rollover or edits made from another one.
  void _select(int i) {
    _closeMenu();
    if (i == _index) return;
    setState(() => _index = i);
    final provider = context.read<TaskProvider>();
    if (i == 0) provider.loadTasks();
    if (i == 1) provider.loadMonth(provider.month);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return PopScope(
      // While the menu is open, back closes it rather than leaving the app.
      canPop: !_isOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeMenu();
      },
      child: Scaffold(
        backgroundColor: p.sidebar,
        body: Stack(
          children: [
            AnimatedBuilder(
              animation: _slide,
              builder: (context, child) => Transform.translate(
                offset: Offset(_menuWidth * _slide.value, 0),
                child: child,
              ),
              child: _Screen(
                // The screen keeps every pixel it had; it has only moved, so
                // nothing on it reflows as the menu opens.
                onTapWhileOpen: _closeMenu,
                isOpen: _menu,
                child: SafeArea(
                  child: IndexedStack(index: _index, children: _pages),
                ),
              ),
            ),
            // On top of the screen and sliding in from off the left edge, so
            // it reads as a panel lifted above the window rather than
            // something uncovered behind it. The screen moves out of its way
            // by exactly its width, so nothing is hidden underneath.
            AnimatedBuilder(
              animation: _slide,
              builder: (context, child) => Transform.translate(
                offset: Offset(-_menuWidth * (1 - _slide.value), 0),
                child: child,
              ),
              child: SizedBox(
                width: _menuWidth,
                child: _Menu(index: _index, onSelected: _select),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The screen as it sits over the menu: rounded off down its left edge once it
/// has moved, with a shadow to lift it, and swallowing taps while the menu is
/// open so the first tap back on it is a close rather than a stray press.
class _Screen extends StatelessWidget {
  final Animation<double> isOpen;
  final VoidCallback onTapWhileOpen;
  final Widget child;

  const _Screen({
    required this.isOpen,
    required this.onTapWhileOpen,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return AnimatedBuilder(
      animation: isOpen,
      builder: (context, inner) {
        final t = isOpen.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: p.bg,
            // Corners only. The menu on top of it is the thing casting a
            // shadow now, and two of them argued about which was in front.
            borderRadius: BorderRadius.circular(22 * t),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22 * t),
            child: Stack(
              children: [
                inner!,
                if (t > 0)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onTapWhileOpen,
                      onHorizontalDragEnd: (d) {
                        if ((d.primaryVelocity ?? 0) < 0) onTapWhileOpen();
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
      child: child,
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
    // A list, not a tick: the screen is a running order of days, and a tick
    // is what sits on each of the rows inside it.
    _TabItem(Icons.list_alt_outlined, Icons.list_alt, 'Schedule'),
    _TabItem(Icons.calendar_month_outlined, Icons.calendar_month, 'Calendar'),
    _TabItem(Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    final overdue = context.watch<TaskProvider>().overdue.length;

    return Material(
      color: p.sidebar,
      // Rounded off down its leading edge and shadowed, so it sits above the
      // window rather than flush against it.
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(24)),
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: 0.6),
      clipBehavior: Clip.antiAlias,
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
