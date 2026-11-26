import 'dart:io';

import 'package:caldo/mcp/worker_usage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'samples host counters and keeps unavailable metrics separate',
    () async {
      final root = await Directory.systemTemp.createTemp('worker-usage-');
      addTearDown(() => root.delete(recursive: true));

      Future<File> write(String path, String contents) async {
        final file = await File('${root.path}/$path').create(recursive: true);
        return file.writeAsString(contents);
      }

      final nvidia = await write(
        'nvidia-smi',
        '#!/bin/sh\nprintf "N/A\\n0\\n37\\n"\n',
      );
      expect((await Process.run('chmod', ['+x', nvidia.path])).exitCode, 0);
      final usage = WorkerUsage(root: root.path, nvidiaSmi: nvidia.path);
      final cpu = await write('proc/stat', 'cpu  100 0 0 100 0 0 0 0 0 0\n');
      final ram = await write(
        'proc/meminfo',
        'MemTotal: 16000 kB\nMemFree: 4000 kB\nMemAvailable: 7000 kB\n',
      );
      final gpu = await write(
        'sys/class/drm/card2/device/gpu_busy_percent',
        '51\n',
      );

      expect(await usage.read(), {
        'ram_used_bytes': 9000 * 1024,
        'ram_total_bytes': 16000 * 1024,
        'gpu_percent': 51,
      });

      await cpu.writeAsString('cpu  125 0 0 160 15 0 0 0 20 0\n');
      await ram.delete();
      await gpu.delete();
      expect(await usage.read(), {'cpu_percent': 25, 'gpu_percent': 37});

      await nvidia.writeAsString('#!/bin/sh\nexit 1\n');
      await cpu.writeAsString('cpu  125 0 0 260 15 0 0 0 20 0\n');
      expect(await usage.read(), {'cpu_percent': 0});
    },
    skip: !Platform.isLinux,
  );
}
