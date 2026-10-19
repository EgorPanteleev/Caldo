import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'menu_button.dart';

/// Identifies a screen header's title text.
const screenTitleKey = Key('screen-title');

/// The header every screen opens with: a back arrow or the menu button, a
/// title, an optional count pill, and trailing actions.
class ScreenHeader extends StatelessWidget {
  final String title;
  final int? count;
  final bool showBack;
  final List<Widget> actions;

  /// Opens the shell's menu. Set on the screens the menu leads to; null on the
  /// ones pushed on top of them, which carry a back arrow instead.
  final VoidCallback? onMenu;

  const ScreenHeader({
    super.key,
    required this.title,
    this.count,
    this.showBack = false,
    this.actions = const [],
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        showBack || onMenu != null ? 4 : 20,
        12,
        12,
        8,
      ),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              icon: Icon(Icons.arrow_back, color: p.muted),
              onPressed: () => Navigator.of(context).maybePop(),
            )
          else if (onMenu != null)
            MenuButton(onTap: onMenu!),
          // The title and its count pill take every pixel the actions leave;
          // a Spacer here would instead split that width with the title and
          // clip long names.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    key: screenTitleKey,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: p.border),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Small uppercase section label in the Obsidian style.
class SectionLabel extends StatelessWidget {
  final String text;
  final Color? color;
  const SectionLabel(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: TextStyle(
          color: color ?? AppTheme.of(context).faint,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// A centred placeholder for an empty list, in the muted Obsidian style.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    // Scrollable so it still fits when the space left under a calendar grid
    // or a header is shorter than the placeholder itself.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: p.faint),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p.muted,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: p.faint, fontSize: 13, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
