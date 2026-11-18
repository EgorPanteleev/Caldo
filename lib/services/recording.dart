import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../utils/platform.dart';
import '../widgets/perf_hud.dart';

/// Settings › Debug's screen recording: a video of the screen
/// (`ScreenRecord.kt`) and, beside it, a log of what the app was doing
/// meanwhile, the two to be sent on together for a look at what went
/// wrong. Android only; a desktop has its own recorders.
///
/// The log is JSON, a line to an event, each with `t`, milliseconds from
/// the video's first frame, and `k`, what it is: `start` (the phone, the
/// build, the screen), `touch` (every pointer down, move and up, in
/// logical points), `frame` (each frame's build and raster times, at its
/// vsync), `perf` (the HUD's numbers, once a second), `route`, `life`,
/// `insets` (the keyboard among them), `error`, `print`, `mark` (the
/// badge's flag) and `stop`. Touches, the HUD's numbers and the time
/// shown in the badge are all in the video too, so the two can be lined
/// up by eye as well as by the clock. Frame times arrive in batches about
/// a second late, so lines are not quite in time order: sort by `t`
/// (`tool/recording.py` does).
class Recording {
  Recording._() {
    _channel.setMethodCallHandler(_heard);
  }

  static final instance = Recording._();

  static const _channel = MethodChannel('caldo/record');

  /// Writes pushed and popped routes to the log, sheets and dialogs
  /// among them; on the app's navigator.
  static final routes = _Routes();

  /// Whether a recording is going: the badge and the touches show while
  /// it is.
  final on = ValueNotifier<bool>(false);

  /// The last recording's files, its video and its log, while kept.
  final kept = ValueNotifier<List<String>>(const []);

  bool get available => !onDesktop;

  /// When the video began, on the monotonic clock, in microseconds.
  int _startUs = 0;
  int? _stopUs;
  IOSink? _sink;
  final _perf = PerfReadings();
  Timer? _second;
  AppLifecycleListener? _life;
  _Insets? _insets;
  FlutterExceptionHandler? _errorsBefore;
  DebugPrintCallback? _printBefore;

  /// How long the recording has been going.
  Duration get elapsed =>
      Duration(microseconds: on.value ? Timeline.now - _startUs : 0);

  /// Finds what the last recording left.
  Future<void> look() async {
    if (!available) return;
    try {
      final files = await _channel.invokeListMethod<String>('files');
      kept.value = files ?? const [];
    } on MissingPluginException {
      kept.value = const [];
    }
  }

  /// Asks Android to let the screen be recorded, and starts once it does.
  /// Null when going or backed out of; otherwise why it could not start.
  Future<String?> start() async {
    if (!available || on.value) return null;
    try {
      final started = await _channel.invokeMapMethod<String, Object?>('start');
      if (started == null) return null;
      await _open(started);
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } on MissingPluginException {
      return 'Not on this device';
    }
  }

  /// Ends it; the log is closed once Android says the video is.
  Future<void> stop() async {
    if (!on.value) return;
    await _channel.invokeMethod<void>('stop');
  }

  /// Notes a moment in the log, for "it went wrong here".
  void mark() => _write('mark');

  /// Hands the last recording to the share sheet.
  Future<bool> share() async {
    final files = kept.value;
    if (files.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('share', {'files': files}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _heard(MethodCall call) async {
    if (call.method == 'stopped') await _close(call.arguments as String?);
  }

  Future<void> _open(Map<String, Object?> started) async {
    _startUs = (started['startedUs']! as num).toInt();
    _stopUs = null;
    final video = started['path']! as String;
    _sink = File(
      video.replaceFirst(RegExp(r'\.mp4$'), '.log.jsonl'),
    ).openWrite();
    Map<String, Object?> device = const {};
    try {
      device = await _channel.invokeMapMethod<String, Object?>('device') ?? {};
    } on PlatformException {
      // The log goes without it.
    }
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final view = dispatcher.implicitView ?? dispatcher.views.first;
    final dpr = view.devicePixelRatio;
    _write('start', {
      'wall': DateTime.now().toIso8601String(),
      'build': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      ...device,
      'video': {
        'w': started['width'],
        'h': started['height'],
        'fps': started['fps'],
      },
      'screen': {
        'w': _one(view.physicalSize.width / dpr),
        'h': _one(view.physicalSize.height / dpr),
        'dpr': dpr,
        'hz': view.display.refreshRate,
      },
      'locale': dispatcher.locale.toLanguageTag(),
      'brightness': dispatcher.platformBrightness.name,
    });
    on.value = true;

    SchedulerBinding.instance.addTimingsCallback(_frames);
    _perf.start();
    _second = Timer.periodic(const Duration(seconds: 1), (_) async {
      final reading = await _perf.read();
      _write('perf', reading);
    });
    _life = AppLifecycleListener(
      onStateChange: (state) => _write('life', {'state': state.name}),
    );
    _insets = _Insets(this)..attach();
    _errorsBefore = FlutterError.onError;
    FlutterError.onError = (details) {
      _write('error', {
        'what': details.exceptionAsString(),
        'stack': details.stack?.toString().split('\n').take(16).join('\n'),
      });
      (_errorsBefore ?? FlutterError.presentError)(details);
    };
    final printBefore = _printBefore = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      _write('print', {'text': message});
      printBefore(message, wrapWidth: wrapWidth);
    };
  }

  Future<void> _close(String? video) async {
    if (!on.value) return;
    _stopUs = Timeline.now;
    _write('stop', {'video': video != null});
    on.value = false;
    _second?.cancel();
    _perf.stop();
    _life?.dispose();
    _insets?.detach();
    FlutterError.onError = _errorsBefore;
    if (_printBefore case final before?) debugPrint = before;
    // The last second's frame times are still to come.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    SchedulerBinding.instance.removeTimingsCallback(_frames);
    final sink = _sink;
    _sink = null;
    await sink?.flush();
    await sink?.close();
    await look();
    // Straight on to the share sheet, unless the notification stopped it
    // from over another app.
    if (video != null &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await share();
    }
  }

  void _frames(List<FrameTiming> timings) {
    for (final t in timings) {
      final at = t.timestampInMicroseconds(FramePhase.vsyncStart);
      if (at < _startUs || (_stopUs != null && at > _stopUs!)) continue;
      _write('frame', {
        'n': t.frameNumber,
        'build': _ms(t.buildDuration),
        'raster': _ms(t.rasterDuration),
        'total': _ms(t.totalSpan),
      }, at);
    }
  }

  /// One pointer event, from the overlay over the whole app.
  void pointer(PointerEvent e) {
    if (_sink == null) return;
    final kind = switch (e) {
      PointerDownEvent() => 'down',
      PointerMoveEvent() => 'move',
      PointerUpEvent() => 'up',
      PointerCancelEvent() => 'cancel',
      _ => null,
    };
    if (kind == null) return;
    _write('touch', {
      'e': kind,
      'id': e.pointer,
      'x': _one(e.position.dx),
      'y': _one(e.position.dy),
    }, e.timeStamp.inMicroseconds);
  }

  void _write(String kind, [Map<String, Object?> data = const {}, int? atUs]) {
    final sink = _sink;
    if (sink == null) return;
    final now = Timeline.now;
    var at = atUs ?? now;
    // Pointer events and frame timings read the same monotonic clock as
    // the video's start on Android; one that is plainly not is not
    // believed, and the line goes at the time it was written.
    if ((at - now).abs() > 10 * Duration.microsecondsPerSecond) at = now;
    sink.writeln(
      jsonEncode({'t': _one((at - _startUs) / 1000), 'k': kind, ...data}),
    );
  }

  static double _one(double v) => (v * 10).round() / 10;

  static double _ms(Duration d) => _one(d.inMicroseconds / 1000);
}

/// The view's insets, written down as they change: the keyboard's above
/// all, which is half of what has ever gone wrong here.
class _Insets with WidgetsBindingObserver {
  final Recording _to;

  _Insets(this._to);

  void attach() {
    WidgetsBinding.instance.addObserver(this);
    didChangeMetrics();
  }

  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeMetrics() {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final view = dispatcher.implicitView ?? dispatcher.views.first;
    final dpr = view.devicePixelRatio;
    double pt(double v) => Recording._one(v / dpr);
    _to._write('insets', {
      'keys': pt(view.viewInsets.bottom),
      'top': pt(view.padding.top),
      'bottom': pt(view.padding.bottom),
      'w': pt(view.physicalSize.width),
      'h': pt(view.physicalSize.height),
    });
  }
}

class _Routes extends NavigatorObserver {
  static String _name(Route<dynamic>? route) =>
      route == null ? '-' : route.settings.name ?? route.runtimeType.toString();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => Recording
      .instance
      ._write('route', {'push': _name(route), 'over': _name(previousRoute)});

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => Recording
      .instance
      ._write('route', {'pop': _name(route), 'back': _name(previousRoute)});

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      Recording.instance._write('route', {
        'replace': _name(oldRoute),
        'with': _name(newRoute),
      });
}
