import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A small check badge shown on the corner of a selected item's icon.
class SelectionCheck extends StatelessWidget {
  const SelectionCheck({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.accentOf(context);
    final p = AppTheme.of(context);
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: accent.color,
        shape: BoxShape.circle,
        border: Border.all(color: p.bg, width: 2),
      ),
      child: const Icon(Icons.check, color: Colors.white, size: 12),
    );
  }
}
