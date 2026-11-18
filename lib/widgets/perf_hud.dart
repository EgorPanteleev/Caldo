import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tweaks.dart';

/// Settings › Debug's numbers on how hard the app is working: frames a
/// second against the display's rate, how long frames take to build and to
/// raster, the CPU the process and its two busiest threads use, memory, and
/// the GPU's load where the system lets an app read it.
///
/// Measured on a release build these are the real thing; a debug build
/// draws at half rate here and its numbers say nothing. Read once a second
/// and drawn once a second, so with nothing else moving the HUD's own frame
/// is the one frame a second it shows. Not stored, like the keyboard's
/// numbers: on until the app is closed. Part of Debug mode: while it is
/// off neither switch does anything, though each keeps where it was.
class PerfHud extends StatelessWidget {
  /// Whether the numbers are on screen.
  static final shown = ValueNotifier<bool>(false);

  /// Whether Flutter's own frame graphs are (`showPerformanceOverlay`).
  static final graphs = ValueNotifier<bool>(false);

  /// Whether the graphs are drawn: switched on, and Debug mode on.
  static bool get graphsDrawn => graphs.value && Tweaks.instance.on;

  final Widget child;

  const PerfHud({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // Always the same Stack, so switching the numbers on or off never
    // remounts the app beneath them.
    return ListenableBuilder(
      listenable: Listenable.merge([shown, Tweaks.instance]),
      builder: (context, _) => Stack(
        fit: StackFit.expand,
        children: [child, if (shown.value && Tweaks.instance.on) const _Hud()],
      ),
    );
  }
}

class _Hud extends StatefulWidget {
  const _Hud();

  @override
  State<_Hud> createState() => _HudState();
}

class _HudState extends State<_Hud> {
  final _probe = _Probe();
  late final Timer _timer;
  _Reading? _reading;

  /// Where the box stands, from the top left, once dragged out of the way.
  /// Until then it stands just above the tab bar: the top is where
  /// Flutter's own graphs go.
  Offset? _at;
  final _box = GlobalKey();

  @override
  void initState() {
    super.initState();
    _probe.start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  Future<void> _read() async {
    final reading = await _probe.read();
    if (mounted) setState(() => _reading = reading);
  }

  @override
  void dispose() {
    _timer.cancel();
    _probe.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final at = _at;
    final hz = View.of(context).display.refreshRate;
    return Positioned(
      left: at?.dx ?? 8,
      top: at?.dy,
      bottom: at == null ? MediaQuery.paddingOf(context).bottom + 100 : null,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          final box = _box.currentContext?.findRenderObject() as RenderBox?;
          if (box == null) return;
          final next = (at ?? box.localToGlobal(Offset.zero)) + d.delta;
          _at = Offset(
            next.dx.clamp(0, math.max(0, size.width - box.size.width)),
            next.dy.clamp(0, math.max(0, size.height - box.size.height)),
          );
        }),
        child: RepaintBoundary(
          key: _box,
          // No Material above the navigator's builder: without a text
          // style of its own the text is underlined in yellow.
          child: DefaultTextStyle(
            style: const TextStyle(decoration: TextDecoration.none),
            child: _Box(reading: _reading, hz: hz),
          ),
        ),
      ),
    );
  }
}

class _Box extends StatelessWidget {
  final _Reading? reading;
  final double hz;

  const _Box({required this.reading, required this.hz});

  static const _green = Color(0xFF7CFF9B);
  static const _amber = Color(0xFFFFD166);
  static const _red = Color(0xFFFF6B6B);

  @override
  Widget build(BuildContext context) {
    final r = reading;
    final budget = 1000 / hz;
    String ms(double v) => v.toStringAsFixed(1);
    String pc(double? v) => v == null ? '—' : '${v.round()}%';
    String mb(int? bytes) => bytes == null
        ? '—'
        : bytes >= 1 << 30
        ? '${(bytes / (1 << 30)).toStringAsFixed(1)}G'
        : '${(bytes / (1 << 20)).round()}M';
    // A frame over the display's budget is a frame dropped.
    Color over(double v) => v > budget
        ? _red
        : v > budget * 0.75
        ? _amber
        : _green;

    final lines = <InlineSpan>[];
    void line(List<(String, Color)> parts) {
      if (lines.isNotEmpty) lines.add(const TextSpan(text: '\n'));
      for (final (text, colour) in parts) {
        lines.add(
          TextSpan(
            text: text,
            style: TextStyle(color: colour),
          ),
        );
      }
    }

    if (r == null) {
      line([('reading…', _green)]);
    } else {
      final f = r.frames;
      line([
        ('${r.fps.toString().padLeft(3)} fps', _green),
        (' / ${hz.round()} Hz', _green),
        ('  slow ${f.janky}', f.janky > 0 ? _red : _green),
        ('  (${r.jankSince} all)', _green),
      ]);
      line([
        ('tickers ${r.tickers}', r.tickers > 0 ? _amber : _green),
        ('  ${r.threads ?? '—'} threads', _green),
      ]);
      if (f.count == 0) {
        line([('build   —      raster   —', _green)]);
      } else {
        line([
          ('build ', _green),
          (ms(f.buildAvg), over(f.buildAvg)),
          ('/', _green),
          (ms(f.buildMax), over(f.buildMax)),
          ('  raster ', _green),
          (ms(f.rasterAvg), over(f.rasterAvg)),
          ('/', _green),
          (ms(f.rasterMax), over(f.rasterMax)),
          (' ms', _green),
        ]);
      }
      line([
        ('cpu ${pc(r.cpu)}', _green),
        ('  ui ${pc(r.ui)}', _green),
        ('  raster ${pc(r.raster)}', _green),
        ('  ${r.cores}c', _green),
      ]);
      line([
        ('gpu ${pc(r.gpu)}', _green),
        ('  mem ${mb(r.rss)}', _green),
        ('  free ${mb(r.available)}', _green),
        if (r.temp != null) ('  ${r.temp!.toStringAsFixed(0)}°C', _green),
      ]);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD9000000),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(children: lines),
              style: const TextStyle(
                fontSize: 10,
                height: 1.3,
                fontFamily: 'monospace',
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            // The last frames' total time, bar by bar, against the budget.
            CustomPaint(
              size: const Size(200, 22),
              painter: _Bars(totals: r?.recent ?? const [], budget: budget),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last frames as bars, tallest at twice the budget; the budget is the
/// line across.
class _Bars extends CustomPainter {
  final List<double> totals;
  final double budget;

  _Bars({required this.totals, required this.budget});

  @override
  void paint(Canvas canvas, Size size) {
    final ceiling = budget * 2;
    final width = size.width / _Probe.kept;
    final paint = Paint();
    for (var i = 0; i < totals.length; i++) {
      final v = totals[i];
      final h = size.height * math.min(1.0, v / ceiling);
      paint.color = v > budget ? _Box._red : _Box._green.withValues(alpha: 0.7);
      final x = size.width - (totals.length - i) * width;
      canvas.drawRect(
        Rect.fromLTWH(x, size.height - h, math.max(1, width - 0.5), h),
        paint,
      );
    }
    final y = size.height - size.height * (budget / ceiling);
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = const Color(0x99FFFFFF)
        ..strokeWidth = 0.5,
    );
  }

  @override
  bool shouldRepaint(_Bars old) => true;
}

/// One second's worth of numbers.
class _Reading {
  final int fps;

  /// Animations asking for frames as the reading was taken. Above none
  /// with nothing moving on screen, something is drawing for nothing.
  final int tickers;
  final _FrameStats frames;
  final int jankSince;
  final List<double> recent;

  /// Of one core, as `top` counts: two busy cores are 200%.
  final double? cpu;
  final double? ui;
  final double? raster;
  final int cores;
  final double? gpu;
  final int? rss;
  final int? available;
  final int? threads;
  final double? temp;

  const _Reading({
    required this.fps,
    required this.tickers,
    required this.frames,
    required this.jankSince,
    required this.recent,
    required this.cpu,
    required this.ui,
    required this.raster,
    required this.cores,
    required this.gpu,
    required this.rss,
    required this.available,
    required this.threads,
    required this.temp,
  });
}

class _FrameStats {
  final int count;
  final int janky;
  final double buildAvg, buildMax, rasterAvg, rasterMax;

  const _FrameStats({
    required this.count,
    required this.janky,
    required this.buildAvg,
    required this.buildMax,
    required this.rasterAvg,
    required this.rasterMax,
  });
}

/// Gathers the numbers: frames as the engine reports them, and the rest
/// from `/proc` and `/sys`, which both Android and Linux have. What the
/// system won't let an app read (most GPUs on Android, often temperatures)
/// comes back null and shows as a dash.
class _Probe {
  /// How many frames the bars keep.
  static const kept = 90;

  /// The engine hands timings over in batches — in release, about once a
  /// second — so the times shown are of the frames reported in the last
  /// two seconds, not of exactly the last one.
  static const _window = Duration(seconds: 2);

  final _timings = <(DateTime, FrameTiming)>[];
  final _recent = <double>[];
  int _jankSince = 0;
  double _budgetMs = 1000 / 60;

  _Ticks? _lastTicks;
  DateTime? _lastAt;
  String? _gpuPath;
  bool _gpuLooked = false;
  List<String>? _thermal;

  void start() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _countFrames();
    _framesSeen = _frames;
  }

  void stop() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  /// Frames begun on the UI thread, counted as they begin, which the
  /// batched timings can't do to the second. A persistent callback asks
  /// for no frame of its own, but can't be taken off again: there is one
  /// for the app's life, counting whether shown or not.
  static int _frames = 0;
  static bool _counting = false;
  int _framesSeen = 0;

  static void _countFrames() {
    if (_counting) return;
    _counting = true;
    SchedulerBinding.instance.addPersistentFrameCallback((_) => _frames++);
  }

  void _onTimings(List<FrameTiming> timings) {
    final now = DateTime.now();
    for (final t in timings) {
      _timings.add((now, t));
      final total = t.totalSpan.inMicroseconds / 1000;
      _recent.add(total);
      if (_overBudget(t)) _jankSince++;
    }
    if (_recent.length > kept) _recent.removeRange(0, _recent.length - kept);
  }

  bool _overBudget(FrameTiming t) =>
      t.buildDuration.inMicroseconds / 1000 > _budgetMs ||
      t.rasterDuration.inMicroseconds / 1000 > _budgetMs;

  Future<_Reading> read() async {
    final display = SchedulerBinding.instance.platformDispatcher.displays;
    if (display.isNotEmpty && display.first.refreshRate > 0) {
      _budgetMs = 1000 / display.first.refreshRate;
    }
    final now = DateTime.now();
    _timings.removeWhere((e) => now.difference(e.$1) > _window);
    final fps = _frames - _framesSeen;
    _framesSeen = _frames;

    final ticks = await _readTicks();
    double? cpu, ui, raster;
    final last = _lastTicks, lastAt = _lastAt;
    if (ticks != null && last != null && lastAt != null) {
      // Ticks are hundredths of a second on both Android and Linux.
      final elapsed = now.difference(lastAt).inMicroseconds / 1e6 * 100;
      if (elapsed > 0) {
        double share(int a, int b) => (a - b) / elapsed * 100;
        cpu = share(ticks.process, last.process);
        ui = share(ticks.ui, last.ui);
        raster = share(ticks.raster, last.raster);
      }
    }
    _lastTicks = ticks;
    _lastAt = now;

    return _Reading(
      fps: fps,
      tickers: SchedulerBinding.instance.transientCallbackCount,
      frames: _stats(),
      jankSince: _jankSince,
      recent: List.of(_recent),
      cpu: cpu,
      ui: ui,
      raster: raster,
      cores: Platform.numberOfProcessors,
      gpu: await _readGpu(),
      rss: ProcessInfo.currentRss,
      available: await _readAvailable(),
      threads: ticks?.threads,
      temp: await _readTemp(),
    );
  }

  _FrameStats _stats() {
    if (_timings.isEmpty) {
      return const _FrameStats(
        count: 0,
        janky: 0,
        buildAvg: 0,
        buildMax: 0,
        rasterAvg: 0,
        rasterMax: 0,
      );
    }
    var build = 0.0, buildMax = 0.0, raster = 0.0, rasterMax = 0.0;
    var janky = 0;
    for (final (_, t) in _timings) {
      final b = t.buildDuration.inMicroseconds / 1000;
      final r = t.rasterDuration.inMicroseconds / 1000;
      build += b;
      raster += r;
      buildMax = math.max(buildMax, b);
      rasterMax = math.max(rasterMax, r);
      if (_overBudget(t)) janky++;
    }
    final n = _timings.length;
    return _FrameStats(
      count: n,
      janky: janky,
      buildAvg: build / n,
      buildMax: buildMax,
      rasterAvg: raster / n,
      rasterMax: rasterMax,
    );
  }

  /// The process's CPU ticks, and those of the threads Dart and the
  /// rasteriser run on. Flutter names its raster thread `N.raster`; Dart
  /// runs on `N.ui` where there is one, and on the main thread where the
  /// engine has merged the two (Android, since Flutter 3.29).
  Future<_Ticks?> _readTicks() async {
    try {
      final process = _cpuOf(await File('/proc/self/stat').readAsString());
      final self = Directory('/proc/self/task');
      var ui = 0, raster = 0, threads = 0;
      int? main;
      var namedUi = false;
      final mainTask = '/$pid';
      await for (final task in self.list()) {
        threads++;
        final String stat;
        try {
          stat = await File('${task.path}/stat').readAsString();
        } on FileSystemException {
          continue; // Ended since it was listed.
        }
        final name = stat.substring(
          stat.indexOf('(') + 1,
          stat.lastIndexOf(')'),
        );
        final ticks = _cpuOf(stat);
        if (name.endsWith('.raster')) raster += ticks;
        if (name.endsWith('.ui')) {
          ui += ticks;
          namedUi = true;
        }
        if (task.path.endsWith(mainTask)) main = ticks;
      }
      return _Ticks(
        process: process,
        ui: namedUi ? ui : (main ?? 0),
        raster: raster,
        threads: threads,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// utime + stime from a `stat` line: the 14th and 15th fields, counted
  /// after the name, which may itself hold spaces and brackets.
  static int _cpuOf(String stat) {
    final rest = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    // rest[0] is field 3 (state), so fields 14 and 15 are rest[11], rest[12].
    return int.parse(rest[11]) + int.parse(rest[12]);
  }

  /// The few places a GPU's load is written down: Qualcomm's and Mali's on
  /// phones, AMD's on a Linux desktop. Looked for once; SELinux keeps most
  /// phones' from an app.
  static const _gpuPaths = [
    '/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage',
    '/sys/kernel/gpu/gpu_busy',
    '/sys/class/misc/mali0/device/utilization',
    '/sys/class/drm/card0/device/gpu_busy_percent',
    '/sys/class/drm/card1/device/gpu_busy_percent',
  ];

  Future<double?> _readGpu() async {
    if (!_gpuLooked) {
      _gpuLooked = true;
      for (final path in _gpuPaths) {
        if (await _gpuAt(path) != null) {
          _gpuPath = path;
          break;
        }
      }
    }
    final path = _gpuPath;
    return path == null ? null : _gpuAt(path);
  }

  static Future<double?> _gpuAt(String path) async {
    try {
      final text = (await File(path).readAsString()).trim();
      final numbers = RegExp(
        r'\d+',
      ).allMatches(text).map((m) => int.parse(m[0]!)).toList();
      if (numbers.isEmpty) return null;
      // kgsl's older `gpubusy` style: busy and total cycles.
      if (numbers.length == 2 && numbers[1] > 100) {
        return numbers[1] == 0 ? 0 : numbers[0] / numbers[1] * 100;
      }
      return numbers.first.toDouble();
    } on FileSystemException {
      return null;
    }
  }

  Future<int?> _readAvailable() async {
    try {
      final info = await File('/proc/meminfo').readAsString();
      final m = RegExp(r'MemAvailable:\s+(\d+) kB').firstMatch(info);
      return m == null ? null : int.parse(m[1]!) * 1024;
    } on FileSystemException {
      return null;
    }
  }

  /// The warmest CPU zone, where they can be read; any zone if none says
  /// it is the CPU's.
  Future<double?> _readTemp() async {
    try {
      _thermal ??= await _thermalZones();
      double? warmest;
      for (final zone in _thermal!) {
        try {
          final v = int.parse((await File('$zone/temp').readAsString()).trim());
          final c = v > 1000 ? v / 1000 : v.toDouble();
          if (c > 0 && c < 150) warmest = math.max(warmest ?? c, c);
        } on Object {
          continue;
        }
      }
      return warmest;
    } on FileSystemException {
      return null;
    }
  }

  static Future<List<String>> _thermalZones() async {
    final zones = <String>[];
    final cpu = <String>[];
    try {
      await for (final e in Directory('/sys/class/thermal').list()) {
        if (!e.path.contains('thermal_zone')) continue;
        zones.add(e.path);
        try {
          final type = (await File(
            '${e.path}/type',
          ).readAsString()).toLowerCase();
          if (type.contains('cpu') || type.contains('x86_pkg')) {
            cpu.add(e.path);
          }
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException {
      return const [];
    }
    return cpu.isNotEmpty ? cpu : zones;
  }
}

class _Ticks {
  final int process, ui, raster, threads;

  const _Ticks({
    required this.process,
    required this.ui,
    required this.raster,
    required this.threads,
  });
}
