import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Samples the machine running the worker. Missing sensors leave only
/// their own fields out of the heartbeat.
class WorkerUsage {
  WorkerUsage({this.root = '', this.nvidiaSmi = 'nvidia-smi'});

  final String root;
  final String nvidiaSmi;
  (int total, int idle)? _lastCpu;
  bool _nvidiaMissing = false;

  Future<Map<String, int>> read() async {
    if (!Platform.isLinux) return {};
    final cpu = await _cpuPercent();
    final ram = await _ram();
    final gpu = await _gpuPercent();
    return {
      'cpu_percent': ?cpu,
      if (ram != null) ...{
        'ram_used_bytes': ram.used,
        'ram_total_bytes': ram.total,
      },
      'gpu_percent': ?gpu,
    };
  }

  Future<int?> _cpuPercent() async {
    final stat = await _readFile('$root/proc/stat');
    final fields = stat?.split('\n').first.trim().split(RegExp(r'\s+'));
    if (fields == null || fields.first != 'cpu' || fields.length < 9) {
      return null;
    }
    // Guest time is already included in user and nice. Count I/O wait
    // with idle time, since the CPU isn't doing work then.
    final ticks = fields.skip(1).take(8).map(int.tryParse).toList();
    if (ticks.any((tick) => tick == null || tick < 0)) return null;
    final total = ticks.fold<int>(0, (sum, tick) => sum + tick!);
    final idle = ticks[3]! + ticks[4]!;
    final last = _lastCpu;
    _lastCpu = (total, idle);
    if (last == null) return null;
    final elapsed = total - last.$1;
    final idleDelta = idle - last.$2;
    if (elapsed <= 0 || idleDelta < 0 || idleDelta > elapsed) return null;
    return (100 * (elapsed - idleDelta) / elapsed).round();
  }

  Future<({int used, int total})?> _ram() async {
    final info = await _readFile('$root/proc/meminfo');
    if (info == null) return null;
    int? kib(String key) {
      final match = RegExp(
        '^$key:'
        r'\s+(\d+) kB$',
        multiLine: true,
      ).firstMatch(info);
      return int.tryParse(match?[1] ?? '');
    }

    final total = kib('MemTotal');
    final available = kib('MemAvailable');
    if (total == null || total <= 0 || available == null || available > total) {
      return null;
    }
    return (used: (total - available) * 1024, total: total * 1024);
  }

  /// A single reading for a multi-GPU host shows its busiest GPU.
  Future<int?> _gpuPercent() async {
    final readings = <int>[...await _nvidia()];
    try {
      await for (final card in Directory('$root/sys/class/drm').list()) {
        if (!RegExp(r'/card\d+$').hasMatch(card.path)) continue;
        final busy = _percent(
          await _readFile('${card.path}/device/gpu_busy_percent'),
        );
        if (busy != null) readings.add(busy);
      }
    } on FileSystemException {
      // Some workers have no DRM devices.
    }
    return readings.fold<int?>(
      null,
      (max, busy) => max == null || busy > max ? busy : max,
    );
  }

  Future<List<int>> _nvidia() async {
    if (_nvidiaMissing) return [];
    final Process process;
    try {
      process = await Process.start(nvidiaSmi, [
        '--query-gpu=utilization.gpu',
        '--format=csv,noheader,nounits',
      ]);
    } on ProcessException catch (e) {
      // Skip future launches when the executable is missing. A driver
      // error can recover on a later sample.
      if (e.errorCode == 2) _nvidiaMissing = true;
      return [];
    }

    try {
      final (exitCode, output, _) = await (
        process.exitCode,
        process.stdout.transform(systemEncoding.decoder).join(),
        process.stderr.drain<void>(),
      ).wait.timeout(const Duration(seconds: 2));
      if (exitCode != 0) return [];
      return [
        for (final line in const LineSplitter().convert(output))
          if (_percent(line) case final int busy) busy,
      ];
    } on Object {
      process.kill(ProcessSignal.sigkill);
      return [];
    }
  }

  static int? _percent(String? text) {
    final value = int.tryParse(text?.trim() ?? '');
    return value != null && value >= 0 && value <= 100 ? value : null;
  }

  static Future<String?> _readFile(String path) async {
    try {
      return await File(path).readAsString();
    } on Exception {
      return null;
    }
  }
}
