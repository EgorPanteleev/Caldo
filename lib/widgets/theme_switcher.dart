import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Wraps the app content and animates theme changes as a smooth full-screen
/// cross-fade: it snapshots the current pixels, applies the new theme instantly
/// underneath, then fades the old snapshot out. Because it fades a single
/// cached bitmap, the transition stays perfectly smooth no matter how many
/// widgets change colour.
class ThemeSwitcher extends StatefulWidget {
  final Widget child;
  const ThemeSwitcher({super.key, required this.child});

  static ThemeSwitcherState? of(BuildContext context) =>
      context.findAncestorStateOfType<ThemeSwitcherState>();

  @override
  State<ThemeSwitcher> createState() => ThemeSwitcherState();
}

class ThemeSwitcherState extends State<ThemeSwitcher>
    with SingleTickerProviderStateMixin {
  final _boundaryKey = GlobalKey();
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  );
  ui.Image? _snapshot;

  @override
  void dispose() {
    _controller.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  /// Snapshot the current UI, run [applyChange] to switch the theme, then
  /// cross-fade from the old snapshot to the freshly-themed UI.
  Future<void> change(VoidCallback applyChange) async {
    if (_snapshot != null) {
      applyChange();
      return;
    }
    final boundary =
        _boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null || !mounted) {
      applyChange();
      return;
    }
    ui.Image image;
    try {
      image = await boundary.toImage(
        pixelRatio: MediaQuery.of(context).devicePixelRatio,
      );
    } catch (_) {
      applyChange();
      return;
    }
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() => _snapshot = image);
    applyChange(); // new theme paints instantly under the snapshot
    await _controller.forward(from: 0);
    final old = _snapshot;
    if (mounted) setState(() => _snapshot = null);
    old?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        if (_snapshot != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _FadePainter(
                    image: _snapshot!,
                    opacity: 1 - Curves.easeInOut.transform(_controller.value),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FadePainter extends CustomPainter {
  final ui.Image image;
  final double opacity;

  _FadePainter({required this.image, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: image,
      fit: BoxFit.fill,
      opacity: opacity.clamp(0.0, 1.0),
      filterQuality: FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_FadePainter old) =>
      old.opacity != opacity || old.image != image;
}
