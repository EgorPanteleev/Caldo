import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'quick_add_bar.dart';

/// The add field in the tab bar's room, carried on the keyboard by Android
/// itself for the length of each of its slides (`KeysCarry.kt`).
///
/// Flutter draws into a surface of its own, which reaches the screen when
/// its frame is done; the keyboard is another window, which Android moves
/// in step with this window's own frames. However exactly Dart works out
/// where the keys are — and from 2.11.29 it had them to within 2pt in every
/// frame of the Galaxy's recordings — its frame and Android's reach the
/// screen together only some of the time, and the field drawn by Flutter
/// was a frame ahead of the keys or a frame behind them, never glued. A
/// view of the activity's own, moved from the slide's progress, is drawn
/// in the very frame Android moves the keys in: the two are applied to the
/// screen as one.
///
/// So the field is kept here as a picture, taken whenever it changes while
/// it is up on the keys, and once more before the keys are asked for. For a
/// slide Android draws that picture at the top of the keys, and Flutter
/// leaves its own copy undrawn
/// ([KeyboardGap.carried]); at rest Flutter draws the field again, and the
/// picture is put away a few frames after — the two in the same place, so
/// the overlap cannot be seen, where a gap between them would be.
abstract final class KeysCarry {
  static const _channel = MethodChannel('caldo/carry');

  /// Whether this device carries the field: Android 11 and later, which
  /// say so in their reports of the keys. Never in a test.
  static bool get can => KeyboardGap.instance.carries;

  /// The time the last picture took to make and send, in milliseconds,
  /// for the recordings.
  static final took = ValueNotifier<double>(0);

  /// Hands the picture over, with where the field rests with no keys.
  static void arm(Map<String, Object> picture) {
    _channel.invokeMethod<void>('arm', picture).catchError((_) {});
  }

  /// Takes the picture back: the field is no longer up on the keys, or
  /// is not to ride them down.
  static void disarm() {
    _channel.invokeMethod<void>('disarm').catchError((_) {});
  }

  /// Flutter's own field is drawn again, where the picture stands.
  static void drawn() {
    _channel.invokeMethod<void>('drawn').catchError((_) {});
  }
}

/// What the field in [CarriedField] tells it: whether it is open, and when
/// it is about to ask for the keys.
abstract interface class FieldCarry {
  /// Whether the field is open: being written in, or about to be. Only an
  /// open field up on the keys is pictured.
  set open(bool value);

  /// Pictures the field as it now stands — open, at rest in the bar's
  /// place — and then calls [then], which asks for the keys. Their slide
  /// is carried only once Android has the picture, and the keys are a
  /// frame or so later for it.
  void raise(VoidCallback then);

  /// Takes the picture back at once: the field is closing without riding
  /// the keys down, as it does once a task has been filed.
  void drop();
}

/// The field in the tab bar's room, pictured for Android to carry on the
/// keys ([KeysCarry]).
class CarriedField extends StatefulWidget {
  final Widget child;

  const CarriedField({super.key, required this.child});

  /// The field's carrier, for the field inside it; null outside the bar's
  /// room.
  static FieldCarry? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_CarryScope>()?.carry;

  @override
  State<CarriedField> createState() => _CarriedFieldState();
}

class _CarriedFieldState extends State<CarriedField> implements FieldCarry {
  _RenderCarried? _render;

  bool _open = false;

  /// Whether the screen is on show: one behind it is not on the keys.
  bool _onShow = true;

  /// What to do once the field is pictured, while a raise waits for it.
  VoidCallback? _then;
  Timer? _giveUp;

  /// Whether Android holds a picture of this field.
  bool _armed = false;

  /// Whether the field has changed since it was last pictured: painted
  /// again, or moved.
  bool _stale = true;

  /// Where the field was last pictured, and its size and scale.
  (double, Size, double)? _where;

  bool _making = false;
  bool _looking = false;
  Timer? _soon;

  @override
  set open(bool value) {
    if (value == _open) return;
    _open = value;
    _look();
  }

  @override
  void raise(VoidCallback then) {
    if (!KeysCarry.can) return then();
    _then = then;
    _open = true;
    _stale = true;
    KeyboardGap.instance.raise();
    // Never kept from the keys for long: a picture that does not come
    // costs the slide being carried, not the keys.
    _giveUp?.cancel();
    _giveUp = Timer(const Duration(milliseconds: 150), _release);
    _look();
  }

  @override
  void drop() {
    _open = false;
    _release();
    _soon?.cancel();
    if (_armed) {
      _armed = false;
      KeysCarry.disarm();
    }
  }

  void _release() {
    _giveUp?.cancel();
    final then = _then;
    _then = null;
    then?.call();
  }

  @override
  void initState() {
    super.initState();
    KeyboardGap.instance.changes.addListener(_look);
    KeyboardGap.instance.carried.addListener(_look);
  }

  @override
  void dispose() {
    KeyboardGap.instance.changes.removeListener(_look);
    KeyboardGap.instance.carried.removeListener(_look);
    _soon?.cancel();
    _release();
    if (_armed) KeysCarry.disarm();
    super.dispose();
  }

  void _painted() {
    _stale = true;
    _look();
  }

  /// Decides after the frame, when the field has been painted as it now
  /// stands.
  void _look() {
    if (_looking || !mounted) return;
    _looking = true;
    final scheduler = SchedulerBinding.instance;
    scheduler.addPostFrameCallback((_) {
      _looking = false;
      _decide();
    });
    // Asked between frames, there may be no frame coming to end.
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      scheduler.ensureVisualUpdate();
    }
  }

  bool get _wanted =>
      KeysCarry.can &&
      _open &&
      _onShow &&
      !KeyboardGap.instance.carried.value &&
      KeyboardGap.up(context);

  void _decide() {
    if (!mounted) return;
    // While Android carries the field it keeps the picture it has; Flutter
    // is not drawing its own then, so there is nothing new to take.
    if (KeyboardGap.instance.carried.value) return;
    if (!_wanted) {
      _soon?.cancel();
      _release();
      if (_armed) {
        _armed = false;
        KeysCarry.disarm();
      }
      return;
    }
    final render = _render;
    if (render == null || !render.hasSize) return;
    final where = _measure(render);
    if (where != _where) _stale = true;
    if (_then != null) {
      _soon?.cancel();
      _arm();
    } else if (_stale || !_armed) {
      // A pause after the last change, so typing pictures the field once
      // a word or so rather than once a letter.
      _soon?.cancel();
      _soon = Timer(const Duration(milliseconds: 60), _arm);
    }
  }

  /// Where the field's foot is at rest, in the view's pixels, with its
  /// size and the view's scale: what a picture is good for.
  (double, Size, double) _measure(_RenderCarried render) {
    final dpr = View.of(context).devicePixelRatio;
    final foot = render.localToGlobal(Offset(0, render.size.height)).dy;
    return ((foot + KeyboardGap.of(context)) * dpr, render.size, dpr);
  }

  Future<void> _arm() async {
    if (_making || !mounted || !_wanted) return;
    final render = _render;
    if (render == null || !render.hasSize || !render.attached) return;
    _making = true;
    _stale = false;
    final started = Timeline.now;
    try {
      final where = _measure(render);
      final (bottom, size, dpr) = where;
      final width = (size.width * dpr).ceil();
      final height = (size.height * dpr).ceil();
      // Taken from the field's foot up, so its foot falls on a whole pixel
      // as it does on screen and the picture lines up with Flutter's own.
      final image = render.picture(
        Rect.fromLTWH(0, size.height - height / dpr, size.width, height / dpr),
        dpr,
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (bytes == null || !mounted || !_wanted) return;
      final view = MediaQueryData.fromView(View.of(context));
      final left = render.localToGlobal(Offset.zero).dx * dpr;
      KeysCarry.arm({
        'picture': bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        ),
        'width': width,
        'height': height,
        'left': left,
        'bottom': bottom,
        'reserved': view.viewPadding.bottom * dpr,
      });
      _armed = true;
      _where = where;
      KeysCarry.took.value = (Timeline.now - started) / 1000;
    } catch (_) {
      // No picture: the slide is left to Flutter, as it was before.
    } finally {
      _making = false;
      // Sent ahead of the keys being asked for, so Android has it first:
      // the two go down one channel to one thread, in order.
      _release();
      if (_stale && mounted) _look();
    }
  }

  @override
  Widget build(BuildContext context) {
    final onShow = TickerMode.of(context);
    if (onShow != _onShow) {
      _onShow = onShow;
      _look();
    }
    return _CarryScope(
      carry: this,
      child: _Carried(
        onPaint: _painted,
        onRender: (render) => _render = render,
        child: widget.child,
      ),
    );
  }
}

class _CarryScope extends InheritedWidget {
  final FieldCarry carry;

  const _CarryScope({required this.carry, required super.child});

  @override
  bool updateShouldNotify(_CarryScope oldWidget) => carry != oldWidget.carry;
}

/// A repaint boundary that says when it is painted, and can be pictured.
class _Carried extends SingleChildRenderObjectWidget {
  final VoidCallback onPaint;
  final void Function(_RenderCarried?) onRender;

  const _Carried({
    required this.onPaint,
    required this.onRender,
    required super.child,
  });

  @override
  _RenderCarried createRenderObject(BuildContext context) {
    final render = _RenderCarried(onPaint);
    onRender(render);
    return render;
  }

  @override
  void updateRenderObject(BuildContext context, _RenderCarried renderObject) {
    renderObject.onPaint = onPaint;
    onRender(renderObject);
  }

  @override
  void didUnmountRenderObject(_RenderCarried renderObject) => onRender(null);
}

class _RenderCarried extends RenderRepaintBoundary {
  VoidCallback onPaint;

  _RenderCarried(this.onPaint);

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }

  /// The field as last painted, [bounds] of it at [pixelRatio].
  ui.Image picture(Rect bounds, double pixelRatio) =>
      (layer! as OffsetLayer).toImageSync(bounds, pixelRatio: pixelRatio);
}
