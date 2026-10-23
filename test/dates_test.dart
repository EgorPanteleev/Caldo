import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/utils/dates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final afternoon = DateTime(2026, 10, 22, 15, 5);

  test('a time is written on whichever clock is asked for', () {
    expect(Dates.time(afternoon, h24: true), '15:05');
    expect(Dates.time(afternoon, h24: false), '3:05 PM');
    expect(
      Dates.clock(const TimeOfDay(hour: 0, minute: 0), h24: false),
      '12:00 AM',
    );
    expect(
      Dates.clock(const TimeOfDay(hour: 9, minute: 30), h24: true),
      '09:30',
    );
  });

  test('with no clock asked for, it is the one Settings chose', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsProvider();
    await settings.update(use24Hour: true);
    expect(Dates.time(afternoon), '15:05');
    await settings.update(use24Hour: false);
    expect(Dates.time(afternoon), '3:05 PM');
  });

  test('the choice is kept for the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsProvider().update(use24Hour: true);
    final next = SettingsProvider();
    await next.load();
    expect(next.use24Hour, isTrue);
  });
}
