import 'package:caldo/models/task_list.dart';
import 'package:caldo/providers/settings_provider.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/colour_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The palette, and colours made on the custom sheet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a colour of its own is stored as its hex and read back', () {
    const colour = Color(0xFF12AB9C);
    final id = ListStyle.idOf(colour);
    expect(id, '#12AB9C');
    expect(ListStyle.isCustom(id), isTrue);
    expect(ListStyle.byId(id).color, colour);
    // The eight the palette used to be keep their ids and their colours.
    expect(ListStyle.byId('pink').color, const Color(0xFFD9528A));
    // Anything unreadable is the app's own violet, as an unknown id was.
    expect(ListStyle.byId('#nothex').id, 'violet');
    expect(ListStyle.byId('gone').id, 'violet');
  });

  test('new groups are offered the old eight first, then the rest', () {
    expect(ListStyle.freeFor({}), 'violet');
    expect(ListStyle.freeFor({'violet', 'blue'}), 'teal');
    final old = ['violet', 'blue', 'teal', 'green', 'amber', 'pink', 'cyan'];
    expect(ListStyle.freeFor({...old, 'orange'}), 'red');
    expect(
      ListStyle.freeFor({for (final s in ListStyle.presets) s.id}),
      'violet',
    );
  });

  testWidgets('the plus makes a colour, which is picked and offered again', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    String? value;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          theme: AppTheme.dark(AppAccent.presets.first),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: StatefulBuilder(
                builder: (context, setState) => ColourSelector(
                  value: value,
                  groupColour: ListStyle.byId('violet').color,
                  sample: 'Essay',
                  onChanged: (v) => setState(() => value = v),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(customColourKey));
    await tester.pumpAndSettle();
    expect(find.text('Essay'), findsOneWidget);
    // Near the strip's start is red; started from violet, it moves.
    final strip = tester.getRect(find.byKey(hueStripKey));
    await tester.tapAt(Offset(strip.left + 20, strip.center.dy));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(ListStyle.isCustom(value), isTrue);
    final hue = HSLColor.fromColor(ListStyle.byId(value).color).hue;
    expect(hue < 20 || hue > 340, isTrue, reason: 'red, not $hue');
    expect(settings.customColours, [value]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('custom_colours'), [value]);
    // Backups carry them.
    expect((await SettingsProvider.exported())['custom_colours'], [value]);

    // The group's colour is still a tap away.
    await tester.tap(find.byIcon(Icons.link));
    await tester.pump();
    expect(value, isNull);
  });
}
