import 'package:caldo/widgets/slide_into_place.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a reordered card is drawn where it stood, then slides', (
    tester,
  ) async {
    final trigger = ValueNotifier<int>(0);
    var order = ['a', 'b'];
    late StateSetter reorder;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            reorder = setState;
            return ListView(
              children: [
                for (final id in order)
                  SlideIntoPlace(
                    key: ValueKey(id),
                    scope: 'test',
                    id: id,
                    trigger: trigger,
                    child: SizedBox(height: 100, child: Text(id)),
                  ),
              ],
            );
          },
        ),
      ),
    );
    final aBefore = tester.getTopLeft(find.text('a')).dy;
    final bBefore = tester.getTopLeft(find.text('b')).dy;

    trigger.value++;
    reorder(() => order = ['b', 'a']);
    await tester.pump();

    // The first frame of the new order still shows the old one. Measured
    // after the frame instead, that frame went out with every card already
    // at its new place, and the slide began by jumping back.
    expect(tester.getTopLeft(find.text('a')).dy, aBefore);
    expect(tester.getTopLeft(find.text('b')).dy, bBefore);

    // A ticker's first tick is its starting time, so halfway is a frame on.
    await tester.pump();
    await tester.pump(SlideIntoPlace.duration ~/ 2);
    final aMid = tester.getTopLeft(find.text('a')).dy;
    expect(aMid, greaterThan(aBefore));
    expect(aMid, lessThan(bBefore));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('a')).dy, bBefore);
    expect(tester.getTopLeft(find.text('b')).dy, aBefore);
  });
}
