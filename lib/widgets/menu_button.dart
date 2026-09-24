import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/task_provider.dart';
import '../theme/app_theme.dart';

/// Identifies the menu button, for tests and for the shell that opens on it.
const menuButtonKey = Key('menu-button');

/// The hamburger at the top left of every screen — the way between Tasks, the
/// calendar and Settings now that there is no tab bar along the bottom.
///
/// It carries a dot when something is overdue, which is the one thing worth
/// pulling the user back to a screen they are not on.
class MenuButton extends StatelessWidget {
  final VoidCallback onTap;

  const MenuButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final overdue = context.watch<TaskProvider>().overdue.isNotEmpty;
    return IconButton(
      key: menuButtonKey,
      tooltip: 'Menu',
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
