import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/grain.dart';

/// Paints grain behind content, over a solid colour if supplied.
class BackgroundSurface extends StatelessWidget {
  final Color? color;
  final PaletteBackground? appearance;
  final BorderRadius radius;
  final Widget child;

  const BackgroundSurface({
    super.key,
    this.color,
    this.appearance,
    this.radius = BorderRadius.zero,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final noise = (appearance ?? AppTheme.of(context).background).noise;
    if (noise == 0 && color == null) return child;
    if (noise > 0) Grain.load();
    return CustomPaint(
      painter: _SurfacePainter(
        color: color,
        radius: radius,
        opacity: noise * 0.0022,
        darken: Theme.of(context).brightness == Brightness.light,
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      ),
      child: child,
    );
  }
}

class _SurfacePainter extends CustomPainter {
  final Color? color;
  final BorderRadius radius;
  final double opacity;
  final bool darken;
  final double pixelRatio;

  _SurfacePainter({
    required this.color,
    required this.radius,
    required this.opacity,
    required this.darken,
    required this.pixelRatio,
  }) : super(repaint: opacity > 0 ? Grain.repaint : null);

  @override
  void paint(Canvas canvas, Size size) {
    final shape = radius.toRRect(Offset.zero & size);
    final fill = color;
    if (fill != null) canvas.drawRRect(shape, Paint()..color = fill);
    if (opacity > 0) {
      Grain.draw(canvas, shape, pixelRatio, opacity, darken: darken);
    }
  }

  @override
  bool shouldRepaint(_SurfacePainter oldDelegate) =>
      color != oldDelegate.color ||
      radius != oldDelegate.radius ||
      opacity != oldDelegate.opacity ||
      darken != oldDelegate.darken ||
      pixelRatio != oldDelegate.pixelRatio;
}

/// Gives each Material route its own opaque, textured background as it moves
/// over another one. The Scaffold still owns insets, ink and snackbars.
class AppScaffold extends StatelessWidget {
  final Color? backgroundColor;
  final bool? resizeToAvoidBottomInset;
  final PreferredSizeWidget? appBar;
  final Widget body;

  const AppScaffold({
    super.key,
    this.backgroundColor,
    this.resizeToAvoidBottomInset,
    this.appBar,
    required this.body,
  });

  @override
  Widget build(BuildContext context) => BackgroundSurface(
    color: backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      appBar: appBar,
      body: body,
    ),
  );
}
