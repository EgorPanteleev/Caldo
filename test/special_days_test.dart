import 'package:caldo/data/holidays.dart';
import 'package:caldo/db/database.dart';
import 'package:caldo/db/sync_store.dart';
import 'package:caldo/l10n/strings.dart';
import 'package:caldo/models/special_day.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/providers/task_provider.dart';
import 'package:caldo/screens/tasks_screen.dart';
import 'package:caldo/services/backup.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    initTestDatabase();
    await initializeDateFormatting();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
  });
  tearDown(() => S.use('en'));

  SpecialDay birthday(String name, int month, int day, {int? year}) =>
      SpecialDay(
        name: name,
        month: month,
        day: day,
        year: year,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  group('a special day', () {
    test('falls on the 28th of February when there is no 29th', () {
      final leap = birthday('Leap', 2, 29, year: 2000);
      expect(leap.inYear(2027), DateTime(2027, 2, 28));
      expect(leap.inYear(2028), DateTime(2028, 2, 29));
    });

    test('comes round next on its day this year, or else next year', () {
      final may = birthday('May', 5, 10);
      expect(may.nextFrom(DateTime(2026, 5, 10)), DateTime(2026, 5, 10));
      expect(may.nextFrom(DateTime(2026, 5, 11)), DateTime(2027, 5, 10));
      expect(may.nextFrom(DateTime(2026, 1, 1)), DateTime(2026, 5, 10));
    });

    test('counts its years only when the year is known', () {
      expect(birthday('A', 3, 1, year: 1996).yearsIn(2026), 30);
      expect(birthday('A', 3, 1, year: 2026).yearsIn(2026), isNull);
      expect(birthday('A', 3, 1).yearsIn(2026), isNull);
      final s = S.current;
      expect(s.specialLine(SpecialKind.birthday, 30), 'Birthday · turns 30');
      expect(s.specialLine(SpecialKind.anniversary, 1), 'Anniversary · 1 year');
      expect(s.specialLine(SpecialKind.other, null), 'Special day');
      S.use('ru');
      expect(
        S.current.specialLine(SpecialKind.anniversary, 5),
        'Годовщина · 5 лет',
      );
    });

    test('a kind from a newer version reads as other', () {
      final read = SpecialDay.fromMap({
        ...birthday('X', 1, 2).toMap(),
        'kind': 'nameday',
      });
      expect(read.kind, SpecialKind.other);
    });
  });

  test('special days stand among the public holidays of their month', () async {
    final provider = TaskProvider();
    await provider.addSpecialDay(birthday('Mum', 1, 1, year: 1960));
    await provider.addSpecialDay(birthday('Dad', 12, 31));
    expect(provider.specialDays.map((d) => d.name), ['Mum', 'Dad']);

    final around = provider.daysAround('GB', DateTime(2027, 1));
    final newYear = around[DateTime(2027, 1, 1)]!;
    // The public holiday first, in green; then the user's, in its colour.
    expect(newYear.first.special, isNull);
    expect(newYear.first.color, AppColors.holiday);
    expect(newYear.last.name, 'Mum');
    expect(newYear.last.special!.yearsIn(2027), 67);
    // The month before is in reach too, for a grid's leading days.
    expect(around[DateTime(2026, 12, 31)]!.single.name, 'Dad');
    // Holidays switched off, the user's days stay.
    expect(
      provider
          .daysAround(null, DateTime(2027, 1))[DateTime(2027, 1, 1)]!
          .single
          .name,
      'Mum',
    );
    expect(
      provider.specialDaysBetween(DateTime(2026, 12, 1), DateTime(2027, 1, 1)),
      [DateTime(2026, 12, 31)],
    );
    // The same map while nothing changed, since the grid asks every frame.
    expect(
      identical(
        provider.daysAround('GB', DateTime(2027, 1)),
        provider.daysAround('GB', DateTime(2027, 1)),
      ),
      isTrue,
    );

    await provider.deleteSpecialDay(provider.specialDays.first.id!);
    expect(
      provider
          .daysAround('GB', DateTime(2027, 1))[DateTime(2027, 1, 1)]!
          .length,
      Holidays.around('GB', DateTime(2027, 1))[DateTime(2027, 1, 1)]!.length,
    );
  });

  test('a special day goes to the server, and its deletion too', () async {
    final provider = TaskProvider();
    await provider.addSpecialDay(birthday('Mum', 4, 2, year: 1960));
    final out = await SyncStore().outgoing();
    final row = out.singleWhere((r) => r.table == 'special_days');
    expect(row.data!['name'], 'Mum');
    expect(row.data!['year'], 1960);
    expect(row.data!.containsKey('id'), isFalse);

    await provider.deleteSpecialDay(provider.specialDays.single.id!);
    final gone = (await SyncStore().outgoing()).singleWhere(
      (r) => r.table == 'special_days',
    );
    expect(gone.deleted, isTrue);
    expect(gone.uuid, row.uuid);
  });

  test('a backup carries them, and one from before leaves them be', () async {
    final provider = await seedProvider();
    await provider.addSpecialDay(birthday('Mum', 4, 2));
    final backup = await Backup.take();
    expect(backup.tables['special_days'], hasLength(1));

    final older = Backup.decode((await Backup.take()).encode()).tables
      ..remove('special_days');
    await AppDatabase.instance.replaceAll(older);
    expect((await AppDatabase.instance.getSpecialDays()).single.name, 'Mum');

    await provider.deleteSpecialDay(provider.specialDays.single.id!);
    await backup.restore(SettingsProvider(), provider);
    expect(provider.specialDays.single.name, 'Mum');
  });

  testWidgets('a birthday puts its day on Schedule, with nothing else on it', (
    tester,
  ) async {
    final today = dayOf(DateTime.now());
    final on = today.add(const Duration(days: 10));
    late TaskProvider provider;
    await tester.runAsync(() async {
      provider = await seedProvider();
      await provider.addSpecialDay(
        birthday('Anna', on.month, on.day, year: on.year - 30),
      );
    });
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TaskProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: const TasksScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Anna'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Birthday · turns 30'), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
  });
}
