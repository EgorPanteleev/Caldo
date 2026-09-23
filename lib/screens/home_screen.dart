import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/task_provider.dart';
import '../theme/app_theme.dart';
import 'agenda_screen.dart';
import 'calendar_screen.dart';
import 'lists_screen.dart';
import 'settings_screen.dart';

/// Top-level shell with a Telegram-style bottom tab bar.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  static const _pages = [
    AgendaScreen(),
    CalendarScreen(),
    ListsScreen(),
    SettingsScreen(),
  ];

  /// Switch tabs, refreshing the dated views so they stay correct across a
  /// midnight rollover or edits made from another tab.
  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    final provider = context.read<TaskProvider>();
    if (i == 0) provider.loadAgenda();
    if (i == 1) provider.loadMonth(provider.month);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _index, children: _pages),
      ),
      bottomNavigationBar: _BottomBar(index: _index, onSelected: _select),
    );
  }
}

class _TabItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _TabItem(this.icon, this.activeIcon, this.label);
}

class _BottomBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelected;

  const _BottomBar({required this.index, required this.onSelected});

  static const _items = [
    _TabItem(Icons.check_circle_outline, Icons.check_circle, 'Today'),
    _TabItem(Icons.calendar_month_outlined, Icons.calendar_month, 'Calendar'),
    _TabItem(Icons.list_alt_outlined, Icons.list_alt, 'Lists'),
    _TabItem(Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    // Elevated capsule surface, lighter than the app background. Uses the
    // lerped palette so it cross-fades smoothly on theme change.
    final capsule = AppTheme.of(context).panelHi;
    // Softer shadow in light mode; lerp via background luminance so it
    // fades rather than snapping at the transition midpoint.
    final t = AppTheme.of(context).bg.computeLuminance().clamp(0.0, 1.0);
    final shadowAlpha = 0.4 - 0.28 * t;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            color: capsule,
            borderRadius: BorderRadius.circular(33),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: shadowAlpha),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < _items.length; i++)
                _TabButton(
                  item: _items[i],
                  selected: index == i,
                  onTap: () => onSelected(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatefulWidget {
  final _TabItem item;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 450),
      vsync: this,
    );
    // Telegram-style pop: scale up past 1.0 then settle back elastically.
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.28), weight: 35),
      TweenSequenceItem(
        tween: Tween(begin: 1.28, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 65,
      ),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(_TabButton old) {
    super.didUpdateWidget(old);
    // Bounce whenever this tab becomes the selected one.
    if (widget.selected && !old.selected) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    HapticFeedback.selectionClick();
    if (widget.selected) _controller.forward(from: 0); // re-tap re-bounces
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    // Inactive icons are bright in dark, muted in light (Telegram style);
    // lerp via the (animated) background luminance so they cross-fade on a
    // theme change instead of snapping. Active uses the accent.
    final t = AppTheme.of(context).bg.computeLuminance().clamp(0.0, 1.0);
    final inactive =
        Color.lerp(const Color(0xFFE6E6EC), const Color(0xFF5C5D6B), t)!;
    final color = widget.selected ? AppTheme.accentOf(context).color : inactive;
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: widget.selected
              ? AppTheme.accentOf(context).color.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
              scale: _scale,
              child: Icon(
                widget.selected ? widget.item.activeIcon : widget.item.icon,
                color: color,
                size: 25,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              widget.item.label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
