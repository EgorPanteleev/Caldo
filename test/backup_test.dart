import 'dart:convert';

import 'package:caldo/db/database.dart';
import 'package:caldo/l10n/strings.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/services/backup.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initTestDatabase);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
  });
  tearDown(() => S.use('en'));

  Matcher problem(BackupProblem p) =>
      throwsA(isA<BackupException>().having((e) => e.problem, 'problem', p));

  test('a backup restores every group, task and tick as it was', () async {
    final provider = await seedProvider();
    await provider.toggleDone(await taskNamed('Ship'));
    final before = await AppDatabase.instance.dump();
    final text = (await Backup.take()).encode();

    // Everything changes after the backup was taken.
    await provider.remove((await taskNamed('Water')).id!);
    await provider.addList(provider.lists.first.copyWith(name: 'Stray'));

    final backup = Backup.decode(text);
    expect(backup.taskCount, 3);
    expect(backup.groupCount, 2);
    await backup.restore(SettingsProvider(), provider);

    expect(await AppDatabase.instance.dump(), before);
    expect((await AppDatabase.instance.getCompletions(0)).single.title, 'Ship');
    expect(provider.lists.map((l) => l.name).toSet(), {'Personal', 'Work'});
    expect(provider.undated.single.title, 'Someday idea');
  });

  test('the group on show is let go, since it may not exist', () async {
    final provider = await seedProvider();
    final text = (await Backup.take()).encode();
    final stray = await provider.addList(
      provider.lists.first.copyWith(name: 'Stray'),
    );
    provider.showGroup(stray.id);
    await Backup.decode(text).restore(SettingsProvider(), provider);
    expect(provider.group, isNull);
  });

  test('settings travel, the phone\'s calendars stay behind', () async {
    SharedPreferences.setMockInitialValues({
      'language': 'ru',
      'use_24_hour': true,
      'reminder_minutes': 480,
      'hidden_screens': ['board'],
      'hidden_calendars': ['7'],
      'show_device_events': true,
    });
    final settings = await SettingsProvider.exported();
    expect(settings, {
      'language': 'ru',
      'use_24_hour': true,
      'reminder_minutes': 480,
      'hidden_screens': ['board'],
    });

    // Restored onto a phone with settings of its own: what the backup has is
    // put back, and what it does not have goes back to its default.
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'light',
      'hidden_calendars': ['3'],
    });
    final backup = Backup.decode(
      Backup(
        savedAt: DateTime(2026, 11, 8),
        schema: AppDatabase.schema,
        tables: await AppDatabase.instance.dump(),
        settings: settings,
      ).encode(),
    );
    final provider = SettingsProvider();
    await backup.restore(provider, TaskProvider());
    expect(provider.languageInForce, 'ru');
    expect(S.current.code, 'ru');
    expect(provider.use24Hour, isTrue);
    expect(provider.reminderMinutes, 480);
    expect(provider.hiddenScreens, {AppScreen.board});
    expect(provider.themeMode, ThemeMode.dark);
    expect(provider.hiddenCalendars, {'3'});
  });

  test(
    'an older backup leaves the columns it lacks to their defaults',
    () async {
      final text = jsonEncode({
        'app': 'caldo',
        'format': 1,
        'schema': 5,
        'savedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'tables': {
          'lists': [
            {'id': 1, 'name': 'Home', 'style_id': 'green', 'created_at': 1},
          ],
          'tasks': [
            // No completions table, no started_at, and a column nothing
            // knows any more.
            {'id': 4, 'list_id': 1, 'title': 'Old', 'created_at': 1, 'gone': 1},
          ],
        },
      });
      await Backup.decode(text).restore(SettingsProvider(), TaskProvider());
      final task = await taskNamed('Old');
      expect(task.id, 4);
      expect(task.startedAt, isNull);
      expect(task.subtasks, isEmpty);
      expect(await AppDatabase.instance.getCompletions(0), isEmpty);
    },
  );

  test('a restore that fails halfway leaves what was there', () async {
    final provider = await seedProvider();
    final backup = Backup(
      savedAt: DateTime.now(),
      schema: AppDatabase.schema,
      tables: {
        'lists': [
          {'id': 1, 'name': 'Home', 'style_id': 'green', 'created_at': 1},
        ],
        'tasks': [
          {'id': 1, 'list_id': 1, 'created_at': 1}, // no title
        ],
      },
      settings: const {},
    );
    await expectLater(
      backup.restore(SettingsProvider(), provider),
      throwsA(anything),
    );
    expect((await allTasks()).map((t) => t.title).toSet(), {
      'Ship',
      'Water',
      'Someday idea',
    });
  });

  test('a file that is not a backup is turned down, and says why', () {
    expect(() => Backup.decode('not json'), problem(BackupProblem.notCaldo));
    expect(() => Backup.decode('[]'), problem(BackupProblem.notCaldo));
    expect(() => Backup.decode(''), problem(BackupProblem.notCaldo));
    final good = {
      'app': 'caldo',
      'format': 1,
      'schema': AppDatabase.schema,
      'savedAt': 0,
      'tables': {
        'lists': [
          {'id': 1, 'name': 'Home', 'created_at': 1},
        ],
      },
    };
    expect(Backup.decode(jsonEncode(good)).groupCount, 1);
    expect(
      () => Backup.decode(jsonEncode({...good, 'app': 'dicty'})),
      problem(BackupProblem.notCaldo),
    );
    expect(
      () => Backup.decode(
        jsonEncode({
          ...good,
          'tables': {'lists': []},
        }),
      ),
      problem(BackupProblem.notCaldo),
    );
    expect(
      () => Backup.decode(
        jsonEncode({...good, 'schema': AppDatabase.schema + 1}),
      ),
      problem(BackupProblem.newer),
    );
  });
}
