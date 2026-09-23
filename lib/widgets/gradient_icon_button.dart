import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A small square button filled with the app's accent gradient — the primary
/// "add" affordance on every screen header.
class GradientIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final String? tooltip;

  /// Round instead of the default rounded square.
  final bool circle;

  const GradientIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 40,
    this.tooltip,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(circle ? size / 2 : 10);
    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: AppTheme.accentOf(context).gradient,
            borderRadius: radius,
          ),
          child: Icon(icon, color: Colors.white, size: size * 0.55),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
