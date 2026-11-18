import 'package:caldo/widgets/keys_carry.dart';
import 'package:caldo/widgets/quick_add_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The field in the bar's room, and what Android is asked over `caldo/carry`.
const _field = Key('field');
const _channel = MethodChannel('caldo/carry');

final _calls = <MethodCall>[];

Widget _harness({void Function(BuildContext)? onField}) => MediaQuery(
  data: const MediaQueryData(
    size: Size(400, 800),
    viewPadding: EdgeInsets.only(bottom: 15),
  ),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.bottomCenter,
      child: FieldInBarRoom(
        child: Builder(
          builder: (context) {
            onField?.call(context);
            return const ColoredBox(
              key: _field,
              color: Colors.white,
              child: SizedBox(height: 60, width: 400),
            );
          },
        ),
      ),
    ),
  ),
);

/// Android's report of the keys at rest, reaching [reach] into the window.
Map<String, Object> _rest(double reach) => {
  'reach': reach,
  'ime': reach,
  'nav': 0.0,
  'below': 0.0,
  'sliding': false,
  'carries': true,
};

double _opacityOver(WidgetTester tester) => tester
    .widget<Opacity>(
      find.ancestor(of: find.byKey(_field), matching: find.byType(Opacity)),
    )
    .opacity;

void main() {
  setUp(() {
    // A phone's view, with the gesture strip at its foot.
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1200, 2400);
    view.devicePixelRatio = 3;
    view.viewPadding = const FakeViewPadding(bottom: 45);
    KeyboardGap.instance.forget();
    _calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          _calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first.reset();
    KeyboardGap.instance.forget();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  testWidgets('a carried slide leaves the field to Android until it rests', (
    tester,
  ) async {
    KeyboardGap.instance.take(_rest(300));
    await tester.pumpWidget(_harness());
    expect(_opacityOver(tester), 1);
    // Up on the keys it stands on a light strip of the ground — no solid
    // band with a fade over it, and no blur: both were asked off.
    final room = find.byType(FieldInBarRoom);
    expect(
      find.descendant(of: room, matching: find.byType(GroundFade)),
      findsNothing,
    );
    expect(
      find.descendant(of: room, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    final strip = find.descendant(
      of: room,
      matching: find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.decoration is BoxDecoration,
      ),
    );
    expect(strip, findsOneWidget);
    // Clear a strip's height above the field, three fifths of the ground at the
    // keys; part of what Android pictures, so it rides the keys with it.
    final field = tester.getRect(find.byKey(_field));
    final under = tester.getRect(strip);
    expect(under.top, field.top - FieldInBarRoom.strip);
    expect(under.bottom, field.bottom);
    final gradient =
        ((tester.widget<DecoratedBox>(strip).decoration as BoxDecoration)
                .gradient!
            as LinearGradient);
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors.last.a, closeTo(0.6, 0.001));
    expect(
      find.descendant(of: find.byType(CarriedField), matching: strip),
      findsOneWidget,
    );

    // Android puts its picture up and moves it with the keys: Flutter's
    // own copy would be a frame off it, so it is not drawn.
    KeyboardGap.instance.take({'carry': true});
    await tester.pump();
    expect(_opacityOver(tester), 0);

    // At rest Flutter draws it again, and once that frame is made says so,
    // for the picture to be put away over a field that is already there.
    KeyboardGap.instance.take(_rest(0));
    await tester.pump();
    expect(_opacityOver(tester), 1);
    expect(_calls.map((c) => c.method), contains('drawn'));
  });

  testWidgets('a raise holds the keys up until they come, or for a second', (
    tester,
  ) async {
    late BuildContext field;
    await tester.pumpWidget(_harness(onField: (c) => field = c));
    expect(KeyboardGap.up(field), isFalse);

    // The field is drawn open in the bar's place while the keys are asked
    // for, so it can be pictured there.
    KeyboardGap.instance.raise();
    await tester.pump();
    expect(KeyboardGap.up(field), isTrue);

    // A report of the keys at no distance is not their coming.
    KeyboardGap.instance.take(_rest(0));
    expect(KeyboardGap.instance.raising.value, isTrue);
    KeyboardGap.instance.take(_rest(280));
    expect(KeyboardGap.instance.raising.value, isFalse);
    expect(KeyboardGap.up(field), isTrue, reason: 'the keys are up now');

    // Keys that never come — a keyboard plugged in — give the bar back.
    KeyboardGap.instance.take(_rest(0));
    KeyboardGap.instance.raise();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(KeyboardGap.instance.raising.value, isFalse);
    await tester.pump();
    expect(KeyboardGap.up(field), isFalse);
  });

  testWidgets('an open field up on the keys is pictured for Android', (
    tester,
  ) async {
    FieldCarry? carry;
    KeyboardGap.instance.take(_rest(300));
    await tester.pumpWidget(
      _harness(onField: (c) => carry = CarriedField.of(c)),
    );
    expect(carry, isNotNull);

    carry!.open = true;
    await tester.pump();
    // A pause after the last change, then the picture is made off the
    // frame — by the engine, in real time.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    final arm = _calls.lastWhere((c) => c.method == 'arm');
    final args = arm.arguments as Map;
    final width = args['width'] as int;
    final height = args['height'] as int;
    // The field and the strip above it, which ride the keys together.
    expect(width, 400 * 3);
    expect(height, (60 + FieldInBarRoom.strip) * 3);
    final picture = args['picture'] as Uint8List;
    expect(picture.length, width * height * 4);
    // Clear at the strip's top; a little of the ground just over the field.
    int alphaAt(int row) => picture[(row * width + width ~/ 2) * 4 + 3];
    expect(alphaAt(0), 0);
    expect(alphaAt((FieldInBarRoom.strip * 3).round() - 1), greaterThan(0));
    // Where it rests with no keys, though pictured lifted on them: the
    // view's foot here, with nothing kept below it, and the strip it
    // never climbs sent along.
    expect(args['bottom'], closeTo(800 * 3, 0.01));
    expect(args['reserved'], 15 * 3);
    // Keys gone, the picture is taken back: nothing else's keys carry it.
    _calls.clear();
    KeyboardGap.instance.take(_rest(0));
    await tester.pump();
    await tester.pump();
    expect(_calls.map((c) => c.method), contains('disarm'));
  });

  testWidgets('nothing is pictured where Android has not said it carries', (
    tester,
  ) async {
    FieldCarry? carry;
    KeyboardGap.instance.covered.value = 300;
    await tester.pumpWidget(
      _harness(onField: (c) => carry = CarriedField.of(c)),
    );
    var asked = false;
    carry!.raise(() => asked = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(asked, isTrue, reason: 'the keys are asked for regardless');
    expect(_calls.map((c) => c.method), isNot(contains('arm')));
  });
}
