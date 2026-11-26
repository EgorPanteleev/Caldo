import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/app_theme.dart';
import 'background_surface.dart';
import 'quick_add_bar.dart' show KeyboardLift;

/// The two actions pinned above the keyboard on an edited form.
class FormActions extends StatelessWidget {
  final VoidCallback? onCancel;
  final VoidCallback? onSave;
  final Widget Function(Widget child)? wrapActions;

  const FormActions({
    super.key,
    required this.onCancel,
    required this.onSave,
    this.wrapActions,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        Flexible(
          child: _FootAction(label: s.cancel, onTap: onCancel),
        ),
        Flexible(
          child: _FootAction(label: s.save, onTap: onSave),
        ),
      ],
    );
    return KeyboardLift(
      child: BackgroundSurface(
        color: AppTheme.of(context).bg,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: wrapActions?.call(actions) ?? actions,
        ),
      ),
    );
  }
}

/// A word at the foot of the form. The same two plain words the picker sheets
/// end with, for the same reason: neither is more the answer than the other.
class _FootAction extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _FootAction({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = AppTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: onTap == null ? p.muted : p.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
