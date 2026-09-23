import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A small square button filled with the app's accent gradient — the primary
/// "add" affordance on every screen header.
class GradientIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final String? tooltip;

  const GradientIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 40,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: AppTheme.accentOf(context).gradient,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.55),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
