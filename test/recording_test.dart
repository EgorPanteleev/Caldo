import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';

import 'package:caldo/services/recording.dart';
import 'package:caldo/theme/tweaks.dart';
import 'package:caldo/widgets/recording_overlay.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('caldo/record');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('a recording writes its log on the video\'s clock', () async {
    final dir = await Directory.systemTemp.createTemp('caldo_record');
    addTearDown(() => dir.delete(recursive: true));
    final video = '${dir.path}/caldo-test.mp4';
    final shared = <List<Object?>>[];
    final startedUs = Timeline.now;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'start':
          File(video).writeAsStringSync('video');
          return {
            'path': video,
            'startedUs': startedUs,
            'width': 1072,
            'height': 1920,
            'fps': 60,
          };
        case 'device':
          return {'model': 'test'};
        case 'files':
          return [video, '${dir.path}/caldo-test.log.jsonl'];
        case 'share':
          shared.add((call.arguments as Map)['files'] as List<Object?>);
          return true;
        case 'stop':
          // Android answers with the video once it is closed.
          await messenger.handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(MethodCall('stopped', video)),
            (_) {},
          );
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    // Sent straight on only while the app is in front.
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    final recording = Recording.instance;
    expect(await recording.start(), isNull);
    expect(recording.on.value, isTrue);
    recording.pointer(
      PointerDownEvent(
        timeStamp: Duration(microseconds: startedUs + 250000),
        position: const Offset(100, 200),
      ),
    );
    recording.mark();
    await recording.stop();
    // The log stays open a moment for the last frame times.
    while (shared.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final lines = File('${dir.path}/caldo-test.log.jsonl')
        .readAsLinesSync()
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
    final kinds = lines.map((l) => l['k']).toList();
    expect(kinds.first, 'start');
    expect(lines.first['model'], 'test');
    expect(kinds, containsAll(['touch', 'mark', 'stop']));
    final touch = lines.firstWhere((l) => l['k'] == 'touch');
    expect(touch['t'], 250.0);
    expect(touch['x'], 100.0);
    expect(touch['e'], 'down');
    expect(shared, hasLength(1));
  });

  testWidgets('the record button is over the app only with Debug mode on', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final asked = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add(call.method);
      return null; // Nothing started: the button stays a button.
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      Recording.instance.button.value = false;
      Tweaks.instance.clear();
    });

    await tester.pumpWidget(
      const MaterialApp(home: RecordingOverlay(child: SizedBox.expand())),
    );
    Recording.instance.button.value = true;
    await tester.pump();
    expect(find.byKey(recordBadgeKey), findsNothing);

    await tester.runAsync(() => Tweaks.instance.setOn(true));
    await tester.pump();
    final dot = find.byKey(recordBadgeKey);
    expect(dot, findsOneWidget);

    await tester.tap(dot);
    await tester.pump();
    expect(asked, contains('start'));
    expect(Recording.instance.on.value, isFalse);
    expect(dot, findsOneWidget);
  });
}
