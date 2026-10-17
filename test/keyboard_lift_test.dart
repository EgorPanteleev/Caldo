import 'package:caldo/widgets/quick_add_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bar whose position is being measured, and the room it leaves at the
/// foot of a list.
const _bar = Key('bar');
const _foot = Key('foot');

const _screen = Size(400, 800);

Widget _harness(double inset) => MediaQuery(
  data: MediaQueryData(
    size: _screen,
    viewInsets: EdgeInsets.only(bottom: inset),
  ),
  child: const Directionality(
    textDirection: TextDirection.ltr,
    child: Column(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(key: _foot, child: KeyboardRoom()),
          ),
        ),
        KeyboardLift(child: SizedBox(key: _bar, height: 60, width: 200)),
      ],
    ),
  ),
);

/// How far the bar's bottom edge is drawn above where it rests with no
/// keyboard. Attached to the keyboard means this is the keyboard's height,
/// and nothing else, at every moment.
late double _rest;

double _bottomGap(WidgetTester tester) =>
    _rest - tester.getBottomLeft(find.byKey(_bar)).dy;

const _frame = Duration(milliseconds: 16);

void main() {
  setUp(KeyboardGap.instance.forget);

  testWidgets('the keys are met wherever they are reported furthest', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(0));
    _rest = tester.getBottomLeft(find.byKey(_bar)).dy;

    // Mid-slide on an edge-to-edge window, `viewInsets` leaves the system
    // bar strip out and the platform does not. The further of the two is
    // where the keys actually are.
    KeyboardGap.instance.covered.value = 228;
    await tester.pumpWidget(_harness(200));
    await tester.pump(_frame);
    expect(_bottomGap(tester), 228, reason: 'the platform knows better here');

    // And on the next slide the inset counts the strip itself. Nothing is
    // added to it — before, a correction was, and the bar spent that whole
    // slide a strip above the keys.
    KeyboardGap.instance.covered.value = 295;
    await tester.pumpWidget(_harness(295));
    await tester.pump(_frame);
    expect(_bottomGap(tester), 295);

    // A platform message that arrives a frame late must not hold the bar
    // over the keys either: whichever reaches further wins, and on the way
    // up that is the fresher number.
    KeyboardGap.instance.covered.value = 200;
    await tester.pumpWidget(_harness(295));
    await tester.pump(_frame);
    expect(
      _bottomGap(tester),
      295,
      reason: 'a stale report cannot drag it down',
    );

    // Keyboard gone: both say so.
    KeyboardGap.instance.covered.value = 0;
    await tester.pumpWidget(_harness(0));
    await tester.pump(_frame);
    expect(_bottomGap(tester), 0);
  });

  testWidgets('the bar sits on the keyboard at every step of a slide', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(0));
    _rest = tester.getBottomLeft(find.byKey(_bar)).dy;
    expect(_bottomGap(tester), 0);

    // A slide reported as it happens, up and back down again. Every report
    // is honoured in the frame it arrives in: the bar's bottom edge is the
    // keyboard's top edge throughout, never a point above or below it.
    for (final inset in [12.0, 44.0, 98.0, 170.0, 232.0, 270.0, 288.0, 295.0]) {
      await tester.pumpWidget(_harness(inset));
      await tester.pump(_frame);
      expect(_bottomGap(tester), inset, reason: 'rising past $inset');
    }
    for (final inset in [220.0, 140.0, 60.0, 0.0]) {
      await tester.pumpWidget(_harness(inset));
      await tester.pump(_frame);
      expect(_bottomGap(tester), inset, reason: 'falling past $inset');
    }
  });

  testWidgets('a keyboard reported in one lump is still arrived at at once', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(0));
    _rest = tester.getBottomLeft(find.byKey(_bar)).dy;

    // Android reports a slide in however many lumps it feels like, and the
    // bar goes wherever it says in the same frame. Softening this is what
    // put the bar behind the keys; a jump in the report is a jump in the
    // keyboard, and the bar is attached to it.
    await tester.pumpWidget(_harness(295));
    await tester.pump();
    expect(_bottomGap(tester), 295);

    await tester.pumpWidget(_harness(0));
    await tester.pump();
    expect(_bottomGap(tester), 0);
  });

  testWidgets('the room at the foot of the list is the keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(0));
    expect(tester.getSize(find.byKey(_foot)).height, 0);

    await tester.pumpWidget(_harness(200));
    await tester.pump();
    expect(tester.getSize(find.byKey(_foot)).height, 200);
  });
}
