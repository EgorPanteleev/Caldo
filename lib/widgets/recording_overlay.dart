import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/recording.dart';

/// What a screen recording shows over the app (`Recording`): a dot under
/// each finger, so the video says where it was touched, and a badge that
/// says it is recording, for how long, and holds a flag to mark a moment
/// and the stop. Hears every pointer event for the log, recording or not,
/// so turning it on never remounts the app beneath.
class RecordingOverlay extends StatefulWidget {
  final Widget child;

  const RecordingOverlay({super.key, required this.child});

  @override
  State<RecordingOverlay> createState() => _RecordingOverlayState();
}

class _RecordingOverlayState extends State<RecordingOverlay> {
  final _touches = _Touches();

  @override
  void dispose() {
    _touches.dispose();
    super.dispose();
  }

  void _heard(PointerEvent e) {
    final recording = Recording.instance;
    if (!recording.on.value) return;
    recording.pointer(e);
    _touches.heard(e);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: Recording.instance.on,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _heard,
        onPointerMove: _heard,
        onPointerUp: _heard,
        onPointerCancel: _heard,
        child: widget.child,
      ),
      builder: (context, on, app) => Stack(
        fit: StackFit.expand,
        children: [
          app!,
          if (on) ...[
            IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _TouchPainter(_touches)),
              ),
            ),
            const _Badge(),
          ],
        ],
      ),
    );
  }
}

/// The fingers down now, and those just lifted, which stay a moment so a
/// quick tap is still in a frame of the video.
class _Touches extends ChangeNotifier {
  static const _linger = Duration(milliseconds: 150);

  final down = <int, Offset>{};
  final lifted = <int, Offset>{};
  final _timers = <int, Timer>{};

  void heard(PointerEvent e) {
    switch (e) {
      case PointerDownEvent() || PointerMoveEvent():
        down[e.pointer] = e.position;
      case PointerUpEvent() || PointerCancelEvent():
        down.remove(e.pointer);
        lifted[e.pointer] = e.position;
        _timers[e.pointer]?.cancel();
        _timers[e.pointer] = Timer(_linger, () {
          _timers.remove(e.pointer);
          lifted.remove(e.pointer);
          notifyListeners();
        });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}

class _TouchPainter extends CustomPainter {
  final _Touches touches;

  _TouchPainter(this.touches) : super(repaint: touches);

  @override
  void paint(Canvas canvas, Size size) {
    // White ringed in black, to show on the ground and on a card alike.
    final fill = Paint()..color = const Color(0x66FFFFFF);
    final rim = Paint()
      ..color = const Color(0xE6FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final edge = Paint()
      ..color = const Color(0x99000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    void ring(Offset at) {
      canvas.drawCircle(at, 18, rim);
      canvas.drawCircle(at, 19.5, edge);
    }

    for (final at in touches.down.values) {
      canvas.drawCircle(at, 18, fill);
      ring(at);
    }
    // Lifted ones ringed only.
    touches.lifted.values.forEach(ring);
  }

  @override
  bool shouldRepaint(_TouchPainter old) => old.touches != touches;
}

/// "● 0:12 ⚑ ■": recording for so long, a flag to mark a moment, and the
/// stop. Redrawn once a second, like the performance numbers. Can be
/// dragged out of the way.
class _Badge extends StatefulWidget {
  const _Badge();

  @override
  State<_Badge> createState() => _BadgeState();
}

class _BadgeState extends State<_Badge> {
  late final Timer _timer;
  int _marks = 0;
  Offset? _at;
  final _box = GlobalKey();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final at = _at;
    final seconds = Recording.instance.elapsed.inSeconds;
    final time =
        '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    const text = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontFamily: 'monospace',
      fontFeatures: [FontFeature.tabularFigures()],
      decoration: TextDecoration.none,
    );
    Widget button(IconData icon, VoidCallback onTap) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        child: Icon(icon, size: 17, color: Colors.white),
      ),
    );
    final badge = DecoratedBox(
      key: _box,
      decoration: BoxDecoration(
        color: const Color(0xD9000000),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 10, right: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xFFFF4545),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(time, style: text),
            const SizedBox(width: 4),
            button(Icons.flag_rounded, () {
              Recording.instance.mark();
              setState(() => _marks++);
            }),
            if (_marks > 0) Text('$_marks', style: text),
            button(Icons.stop_rounded, Recording.instance.stop),
          ],
        ),
      ),
    );
    final draggable = GestureDetector(
      onPanUpdate: (d) => setState(() {
        final box = _box.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) return;
        final next = (at ?? box.localToGlobal(Offset.zero)) + d.delta;
        _at = Offset(
          next.dx.clamp(0, math.max(0, size.width - box.size.width)),
          next.dy.clamp(0, math.max(0, size.height - box.size.height)),
        );
      }),
      child: badge,
    );
    // Centred under the status bar until dragged.
    if (at == null) {
      return Positioned(
        left: 0,
        right: 0,
        top: MediaQuery.paddingOf(context).top + 6,
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: draggable,
        ),
      );
    }
    return Positioned(left: at.dx, top: at.dy, child: draggable);
  }
}
