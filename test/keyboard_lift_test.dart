import 'package:caldo/widgets/quick_add_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bar whose rise is being measured, and the room it leaves at the foot
/// of a list.
const _bar = Key('bar');
const _foot = Key('foot');

Widget _harness(double inset) => MediaQuery(
  data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
  child: const Directionality(
    textDirection: TextDirection.ltr,
    child: KeyboardInset(
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
  ),
);

/// Where the bar is drawn, measured upwards from where it sits with no
/// keyboard — which is the lift itself.
double _lift(WidgetTester tester, double rest) =>
    rest - tester.getTopLeft(find.byKey(_bar)).dy;

const _frame = Duration(milliseconds: 16);

void main() {
  testWidgets('a keyboard that reports every frame is followed exactly', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(0));
    final rest = tester.getTopLeft(find.byKey(_bar)).dy;

    // Twelve frames of twenty points: a slide reported as it happens. The
    // bar is on the keys at every one of them, with no lag of its own.
    for (var i = 1; i <= 12; i++) {
      await tester.pumpWidget(_harness(20.0 * i));
      await tester.pump(_frame);
      expect(
        _lift(tester, rest),
        moreOrLessEquals(20.0 * i, epsilon: 0.01),
        reason: 'frame $i',
      );
    }
  });

  testWidgets('a keyboard reported in one lump is moved to, not jumped to', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(0));
    final rest = tester.getTopLeft(find.byKey(_bar)).dy;

    await tester.pumpWidget(_harness(240));
    await tester.pump(_frame);
    var last = _lift(tester, rest);
    expect(last, lessThan(240), reason: 'the whole lump in one frame');

    // No frame of the catch-up covers more than the keyboard itself would —
    // that is the difference between a movement and a teleport — and it is
    // over within a few frames of what the keys took.
    var frames = 1;
    while (last < 239.5 && frames < 40) {
      await tester.pump(_frame);
      frames++;
      final now = _lift(tester, rest);
      expect(now - last, lessThan(40), reason: 'frame $frames jumped');
      expect(
        now,
        greaterThanOrEqualTo(last),
        reason: 'frame $frames went back',
      );
      last = now;
    }
    expect(last, moreOrLessEquals(240, epsilon: 0.5));
    expect(frames, lessThan(20), reason: '${frames * 16}ms to catch up');
  });

  testWidgets('the room at the foot of the list is the lift', (tester) async {
    await tester.pumpWidget(_harness(0));
    expect(tester.getSize(find.byKey(_foot)).height, 0);

    await tester.pumpWidget(_harness(200));
    for (var i = 0; i < 20; i++) {
      await tester.pump(_frame);
    }
    expect(tester.getSize(find.byKey(_foot)).height, moreOrLessEquals(200));
  });
}
