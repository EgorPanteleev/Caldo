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

/// A contextual action bar shown at the top while items are selected
/// (entered by long-pressing an item). Shows a count, an optional Edit action
/// (typically only when exactly one item is selected) and a Delete action.
class SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onClose;
  final VoidCallback? onEdit;
  final VoidCallback onDelete;

  const SelectionBar({
    super.key,
    required this.count,
    required this.onClose,
    this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    final accent = AppTheme.accentOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 8, 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close, color: p.text),
            tooltip: 'Cancel',
            onPressed: onClose,
          ),
          Text('$count selected',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          if (onEdit != null)
            IconButton(
              icon: Icon(Icons.edit_outlined, color: accent.color),
              tooltip: 'Edit',
              onPressed: onEdit,
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: AppColors.danger),
            tooltip: 'Delete',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
