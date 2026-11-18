import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/recording.dart';
import '../theme/tweaks.dart';

/// The badge, or the button it is while nothing records, for tests.
const recordBadgeKey = ValueKey('recordBadge');

/// What a recording shows over the app (`Recording`): a dot under each
/// finger, so the video says where it was touched, and a badge that says
/// it is recording, for how long, and holds a flag to mark a moment and
/// the stop. With Debug's "Button on every screen" on, the badge is there
/// while nothing records too, as a red dot that starts a recording from
/// wherever the trouble is. Hears every pointer event for the log,
/// recording or not, so turning it on never remounts the app beneath.
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
    final recording = Recording.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        recording.on,
        recording.button,
        Tweaks.instance,
      ]),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _heard,
        onPointerMove: _heard,
        onPointerUp: _heard,
        onPointerCancel: _heard,
        child: widget.child,
      ),
      builder: (context, app) {
        final on = recording.on.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            app!,
            if (on)
              IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(painter: _TouchPainter(_touches)),
                ),
              ),
            if (on || recording.buttonShown) const _Badge(),
          ],
        );
      },
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
/// stop; while nothing records, the dot alone, which starts one. Stands
/// at the right edge, a little above the middle, clear of the titles and
/// the plus, and grows leftwards; dragged elsewhere it stays there until
/// the app is closed. Redrawn once a second while recording, like the
/// performance numbers, and not at all while idle.
class _Badge extends StatefulWidget {
  const _Badge();

  @override
  State<_Badge> createState() => _BadgeState();
}

class _BadgeState extends State<_Badge> {
  /// Where it stands: from the right edge, and from the top as a share of
  /// the height until dragged. Kept across the badge's comings and goings.
  static double _right = 8;
  static double? _top;

  Timer? _timer;
  int _marks = 0;
  bool _starting = false;
  final _box = GlobalKey();

  @override
  void initState() {
    super.initState();
    Recording.instance.on.addListener(_onChanged);
    _onChanged();
  }

  @override
  void dispose() {
    Recording.instance.on.removeListener(_onChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _onChanged() {
    final on = Recording.instance.on.value;
    _timer?.cancel();
    _timer = on
        ? Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}))
        : null;
    if (on) _marks = 0;
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    final problem = await Recording.instance.start();
    if (problem != null) debugPrint('Could not record: $problem');
    if (mounted) setState(() => _starting = false);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final on = Recording.instance.on.value;
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
    final dot = Container(
      width: on ? 8 : 12,
      height: on ? 8 : 12,
      decoration: BoxDecoration(
        color: Color(_starting ? 0x99FF4545 : 0xFFFF4545),
        shape: BoxShape.circle,
      ),
    );
    final Widget content;
    if (on) {
      final seconds = Recording.instance.elapsed.inSeconds;
      final time =
          '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
      content = Padding(
        padding: const EdgeInsets.only(left: 10, right: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            dot,
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
      );
    } else {
      // The same height as the badge it becomes, and round.
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _start,
        child: SizedBox(width: 27, height: 27, child: Center(child: dot)),
      );
    }
    final badge = DecoratedBox(
      key: _box,
      decoration: BoxDecoration(
        color: const Color(0xD9000000),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF), width: 0.8),
      ),
      child: content,
    );
    final top = _top ?? size.height * 0.42;
    return Positioned(
      right: _right,
      top: top,
      child: GestureDetector(
        key: recordBadgeKey,
        onPanUpdate: (d) => setState(() {
          final box = _box.currentContext?.findRenderObject() as RenderBox?;
          if (box == null) return;
          _right = (_right - d.delta.dx).clamp(
            0,
            math.max(0, size.width - box.size.width),
          );
          _top = (top + d.delta.dy).clamp(
            0,
            math.max(0, size.height - box.size.height),
          );
        }),
        child: badge,
      ),
    );
  }
}
