import 'package:caldo/widgets/quick_add_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

  testWidgets('in a slide the platform is followed alone', (tester) async {
    await tester.pumpWidget(_harness(0));
    _rest = tester.getBottomLeft(find.byKey(_bar)).dy;

    // Closing: the platform says where the keys are about to be, already
    // lower than where `viewInsets` says they were. The further of the two
    // would hold the field above the keys for the whole slide.
    KeyboardGap.instance.sliding = true;
    KeyboardGap.instance.covered.value = 180;
    await tester.pumpWidget(_harness(250));
    await tester.pump(_frame);
    expect(_bottomGap(tester), 180, reason: 'the keys are going, not gone');

    // Settled: the further of the two again.
    KeyboardGap.instance.sliding = false;
    KeyboardGap.instance.covered.value = 0;
    await tester.pumpWidget(_harness(0));
    await tester.pump(_frame);
    expect(_bottomGap(tester), 0);
  });

  testWidgets('a slide is read at each frame, not as its reports land', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(0));
    _rest = tester.getBottomLeft(find.byKey(_bar)).dy;
    // Flutter stamps a frame with the vsync it is to be shown at, one
    // period after the vsync it starts at, which is what Android stamps
    // its reports with. Here the period is a pump's 16ms: a report made
    // at `start` belongs to the frame the next pump makes.
    int now() =>
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    final start = now();
    Map<String, Object> report(int ms, double fraction, {bool curve = false}) =>
        {
          'reach': 300 * fraction,
          'ime': 300 * fraction,
          'nav': 0.0,
          'below': 0.0,
          'sliding': true,
          'slide': 1,
          'at': start + ms * 1000,
          'period': 16000.0,
          'fraction': fraction,
          'length': 160.0,
          'from': 0.0,
          'to': 300.0,
          // Twice as fast in its first half as its second.
          if (curve) 'curve': [0.0, 2 / 3, 1.0],
        };

    // Not yet moved: where it starts from is not known, and it is held.
    KeyboardGap.instance.take(report(0, 0, curve: true));
    await tester.pump(_frame);
    expect(_bottomGap(tester), 0);
    await tester.pump(_frame);
    expect(_bottomGap(tester), 0);

    // Moved: each frame after is placed where the keys are at the vsync it
    // starts at, with nothing more sent.
    KeyboardGap.instance.take(report(16, 0.1));
    await tester.pump(_frame);
    expect(_bottomGap(tester), closeTo(80, 0.01));
    await tester.pump(_frame);
    expect(_bottomGap(tester), closeTo(120, 0.01));

    // A report that lands late, or two at once, says the same of the
    // slide and moves nothing.
    KeyboardGap.instance.take(report(32, 0.2));
    KeyboardGap.instance.take(report(48, 0.3));
    await tester.pump(_frame);
    expect(_bottomGap(tester), closeTo(160, 0.01));

    // Its second half, slower.
    await tester.pump(const Duration(milliseconds: 48));
    expect(_bottomGap(tester), closeTo(240, 0.01));

    // Past its end it holds, and asks for no more frames.
    await tester.pump(const Duration(milliseconds: 80));
    expect(_bottomGap(tester), 300);
    await tester.pump(_frame);
    expect(tester.binding.hasScheduledFrame, isFalse);

    // A slide with no clock (a swipe back) is carried on at the speed of
    // its last two reports, to the vsync each frame starts at, and no more
    // than a frame and a half past the last.
    Map<String, Object> swiped(int at, double reach) => {
      ...report(0, 0),
      'slide': 'none',
      'reach': reach,
      'at': at,
      'period': 8000.0,
    };
    tester.binding.scheduleFrame();
    await tester.pump();
    final t = now();
    KeyboardGap.instance.take(swiped(t - 8000, 160));
    KeyboardGap.instance.take(swiped(t, 150));
    await tester.pump(_frame);
    expect(_bottomGap(tester), closeTo(140, 0.01));
    await tester.pump(_frame);
    expect(_bottomGap(tester), closeTo(135, 0.01));
    await tester.pump(_frame);
    expect(tester.binding.hasScheduledFrame, isFalse);
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
