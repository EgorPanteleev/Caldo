import 'package:flutter/material.dart';

import '../models/task_list.dart';
import '../theme/app_theme.dart';

/// The row of colour swatches a task or a setting picks from: the list's own
/// colour first, marked with a link rather than a colour of its own, then one
/// swatch per preset.
class ColourSelector extends StatelessWidget {
  final String? value;
  final Color listColor;
  final ValueChanged<String?> onChanged;

  const ColourSelector({
    super.key,
    required this.value,
    required this.listColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _Swatch(
          color: listColor,
          selected: value == null,
          // The "same as the list" choice, marked with a link rather than a
          // colour of its own.
          icon: Icons.link,
          onTap: () => onChanged(null),
          border: p.border,
        ),
        for (final style in ListStyle.presets)
          _Swatch(
            color: style.color,
            selected: value == style.id,
            onTap: () => onChanged(style.id),
            border: p.border,
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final IconData? icon;
  final Color border;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.border,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 1 : 0.35),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? AppTheme.of(context).text : border,
            width: selected ? 2 : 1,
          ),
        ),
        child: icon != null
            ? Icon(icon, size: 17, color: Colors.white)
            : (selected
                ? const Icon(Icons.check, size: 18, color: Colors.white)
                : null),
      ),
    );
  }
}
