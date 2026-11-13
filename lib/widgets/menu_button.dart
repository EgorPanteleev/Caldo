import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/task_provider.dart';
import '../theme/app_theme.dart';

/// Identifies the menu button, for tests and for the shell that opens on it.
const menuButtonKey = Key('menu-button');

/// The hamburger at the top left of every screen, when Settings has the
/// screens in a menu rather than in the tab bar along the foot.
///
/// It carries a dot when something is overdue, which is the one thing worth
/// pulling the user back to a screen they are not on.
class MenuButton extends StatelessWidget {
  final VoidCallback onTap;

  const MenuButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final overdue = context.select<TaskProvider, bool>(
      (p) => p.allOverdue.isNotEmpty,
    );
    return IconButton(
      key: menuButtonKey,
      tooltip: S.of(context).menu,
      onPressed: onTap,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.menu, color: p.text, size: 25),
          if (overdue)
            Positioned(
              top: -3,
              right: -4,
              child: Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: AppColors.overdue,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Hands the way to open the shell's menu down to the headers that draw
/// [MenuButton], while the screens are in a menu. Null, or no scope at all —
/// the tab bar on, or a screen pushed over the shell — and there is no
/// button.
class MenuScope extends InheritedWidget {
  final VoidCallback? open;

  const MenuScope({super.key, required this.open, required super.child});

  static VoidCallback? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MenuScope>()?.open;

  @override
  bool updateShouldNotify(MenuScope oldWidget) => oldWidget.open != open;
}
