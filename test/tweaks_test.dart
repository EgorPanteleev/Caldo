import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/theme/tweaks.dart';
import 'package:caldo/widgets/perf_hud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Tweaks.instance.clear();
  });

  test('hex is written and read back', () {
    const grey = Color(0xFF111112);
    expect(Tweaks.hex(grey), '#111112');
    expect(Tweaks.parse('#111112'), grey);
    expect(Tweaks.parse('111112'), grey);
    expect(Tweaks.parse('#fff'), const Color(0xFFFFFFFF));
    expect(Tweaks.hex(const Color(0x80FF0000)), '#80FF0000');
    expect(Tweaks.parse('#80FF0000'), const Color(0x80FF0000));
    expect(Tweaks.parse('nope'), isNull);
  });

  test('colours apply only while debug mode is on', () async {
    final t = Tweaks.instance;
    const red = Color(0xFFFF0000);
    await t.setColour('dark.bg', red);
    await t.setColour('overdue', red);
    await t.setNumber('cardInk', 2);

    expect(t.applyTo(AppPalette.dark, 'dark').bg, AppColors.darkBg);
    expect(AppColors.overdue, isNot(red));
    expect(Tweaks.cardInk, 1);

    await t.setOn(true);
    expect(t.applyTo(AppPalette.dark, 'dark').bg, red);
    expect(t.applyTo(AppPalette.light, 'light').bg, AppColors.lightBg);
    expect(AppColors.overdue, red);
    expect(Tweaks.cardInk, 2);
    expect(AppTheme.dark(AppAccent.presets.first).scaffoldBackgroundColor, red);
  });

  test('what is set is kept, and copies across as text', () async {
    final t = Tweaks.instance;
    await t.setOn(true);
    await t.setColour('light.text', const Color(0xFF123456));
    await t.setNumber('chipInk', 0.5);
    final text = t.asText;

    t.clear();
    await t.load();
    expect(t.on, isTrue);
    expect(t.stored('light.text'), const Color(0xFF123456));

    await t.reset();
    expect(t.count, 0);
    expect(await t.paste(text), isTrue);
    expect(t.on, isTrue);
    expect(t.storedNumber('chipInk'), 0.5);
    expect(await t.paste('not json'), isFalse);
  });

  testWidgets('debug mode off takes the performance numbers with it', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: PerfHud(child: SizedBox()),
      ),
    );
    await tester.runAsync(() => Tweaks.instance.setOn(true));
    // Not pumped with them on: the box itself would start reading /proc.
    PerfHud.shown.value = true;
    PerfHud.graphs.value = true;

    await tester.runAsync(() => Tweaks.instance.setOn(false));
    expect(PerfHud.shown.value, isFalse);
    expect(PerfHud.graphs.value, isFalse);
  });
}
