import 'package:caldo/l10n/strings.dart';
import 'package:caldo/services/account.dart';
import 'package:caldo/widgets/sign_in_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a name is kept as an address that can receive no mail', () {
    expect(Account.loginOf(' Egor '), 'egor@caldo.invalid');
    expect(Account.nameIn('egor@caldo.invalid'), 'egor');
    // An account made when sign-in was by email shows its address.
    expect(Account.nameIn('me@caldo.test'), 'me@caldo.test');
  });

  test('a name is what an address can carry before its @', () {
    for (final ok in ['egor', 'Egor.P', 'a_b-c', 'x1y', 'a' * 32]) {
      expect(Account.fitsName(ok), isTrue, reason: ok);
    }
    for (final bad in [
      'ab',
      'a' * 33,
      '.egor',
      'egor.',
      'e..g',
      'егор',
      'e g',
      'e@g',
    ]) {
      expect(Account.fitsName(bad), isFalse, reason: bad);
    }
  });

  test('an invite is read from the link or from the code alone', () {
    expect(Account.inviteIn('caldo://invite/K7QM2XAB4PQR'), 'K7QM2XAB4PQR');
    expect(Account.inviteIn('  k7qm-2xab-4pqr '), 'K7QM2XAB4PQR');
    expect(Account.linkTo('K7QM2XAB4PQR'), 'caldo://invite/K7QM2XAB4PQR');
  });

  testWidgets('the sheet turns down a bad name or password unsent', (
    tester,
  ) async {
    S.use('en');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showJoinSheet(context, invite: 'K7QM2XAB4PQR'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // A link brought the invite, so it is not asked for.
    expect(find.byKey(signInInviteKey), findsNothing);

    // Nothing here can reach a server: had either been sent, the client
    // that is never made in a test would have thrown instead.
    await tester.enterText(find.byKey(signInNameKey), 'e g');
    await tester.enterText(find.byKey(signInPasswordKey), 'secret123');
    await tester.tap(find.text(S.current.syncJoinAction));
    await tester.pump();
    expect(find.text(S.current.syncBadName), findsOneWidget);

    await tester.enterText(find.byKey(signInNameKey), 'egor');
    await tester.enterText(find.byKey(signInPasswordKey), '12345');
    await tester.tap(find.text(S.current.syncJoinAction));
    await tester.pump();
    expect(find.text(S.current.syncShortPassword(6)), findsOneWidget);
  });
}
