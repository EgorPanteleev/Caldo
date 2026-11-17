import 'package:caldo/db/database.dart';
import 'package:caldo/l10n/strings.dart';
import 'package:caldo/models/secret.dart';
import 'package:caldo/providers/vault_provider.dart';
import 'package:caldo/screens/vault_screen.dart';
import 'package:caldo/services/sealing.dart';
import 'package:caldo/theme/app_theme.dart';
import 'package:caldo/widgets/vault_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_db.dart';

/// The vault's faces and sheets, on a small phone in every language: a
/// word that does not fit is an overflow, which fails the test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initTestDatabase);

  late AppDatabase db;
  late VaultProvider vault;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/vault_screen.db');
    db = AppDatabase.named('vault_screen.db');
    vault = VaultProvider(db: db, kdf: Kdf.quick);
  });

  tearDown(() async {
    S.use('en');
    vault.dispose();
    await db.close();
  });

  Future<void> pumpVault(WidgetTester tester, String code) async {
    tester.view.physicalSize = const Size(960, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // Read in real time; the screen's own start then finds it done.
    await tester.runAsync(vault.start);
    await tester.pumpWidget(
      ChangeNotifierProvider<VaultProvider>.value(
        value: vault,
        child: MaterialApp(
          locale: Locale(code),
          supportedLocales: S.supported,
          localizationsDelegates: const [
            S.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.dark(AppAccent.presets.first),
          home: const VaultScreen(),
        ),
      ),
    );
    await settle(tester);
  }

  for (final code in S.names.keys) {
    testWidgets('the vault fits in ${S.names[code]}', (tester) async {
      final s = S.forCode(code);
      await pumpVault(tester, code);
      expect(find.text(s.vaultSetUpTitle), findsOneWidget);

      await tester.runAsync(() async {
        await vault.create('master pass');
        await vault.save(
          const Secret(
            title: 'A rather long name for a bank account',
            login: 'someone.with.a.long.address@example.com',
            password: 'correct horse battery staple',
            website: 'https://bank.example.com/login',
            notes: 'Security questions: the first school.',
            fields: [SecretField(name: 'PIN', value: '0451', hidden: true)],
          ),
        );
        // One from a vault made elsewhere, which this one cannot open.
        await db.putSecret(
          uuid: Sealing.uuid(),
          keyId: 'elsewhere',
          sealed: 'sealed',
          createdAt: 0,
        );
        await vault.reload();
      });
      await settle(tester);
      expect(find.text(s.vaultSealedElsewhere(1)), findsOneWidget);

      await tester.tap(find.text('A rather long name for a bank account'));
      await settle(tester);
      expect(find.text(s.vaultEdit), findsOneWidget);
      await tester.tap(find.text(s.vaultEdit));
      await settle(tester);
      expect(find.text(s.vaultAddField), findsOneWidget);
      await tester.tap(find.byKey(secretGenerateKey));
      await settle(tester);
      expect(find.text(s.vaultUse), findsOneWidget);
      await tester.tap(find.text(s.vaultUse));
      await settle(tester);
      Navigator.of(tester.element(find.text(s.vaultAddField))).pop();
      await settle(tester);
      Navigator.of(tester.element(find.text(s.vaultEdit))).pop();
      await settle(tester);

      await tester.tap(find.byTooltip(s.vaultSettings));
      await settle(tester);
      expect(find.text(s.vaultChangePassword), findsOneWidget);
      Navigator.of(tester.element(find.text(s.vaultChangePassword))).pop();
      await settle(tester);

      await tester.tap(find.byTooltip(s.vaultLock));
      await settle(tester);
      expect(find.text(s.vaultLocked), findsOneWidget);
    });
  }

  testWidgets('a vault is made, filled and locked from the screen', (
    tester,
  ) async {
    await pumpVault(tester, 'en');
    await tester.enterText(find.byKey(vaultPasswordKey), 'short');
    await tester.enterText(find.byKey(vaultRepeatKey), 'short');
    await tester.tap(find.byKey(vaultGoKey));
    await settle(tester);
    expect(find.text('At least 8 characters'), findsOneWidget);

    await tester.enterText(find.byKey(vaultPasswordKey), 'master pass');
    await tester.enterText(find.byKey(vaultRepeatKey), 'master pas');
    await tester.tap(find.byKey(vaultGoKey));
    await settle(tester);
    expect(find.text("The passwords don't match"), findsOneWidget);

    await tester.enterText(find.byKey(vaultRepeatKey), 'master pass');
    await tester.tap(find.byKey(vaultGoKey));
    await until(tester, () => vault.state == VaultState.open);
    expect(find.text('Nothing here yet'), findsOneWidget);

    await tester.tap(find.byTooltip('New secret'));
    await settle(tester);
    await tester.enterText(find.byKey(secretTitleKey), 'Mail');
    await tester.tap(find.text('Save'));
    await until(tester, () => vault.secrets.isNotEmpty);
    await settle(tester);
    expect(find.text('Mail'), findsOneWidget);
    expect(vault.secrets.single.title, 'Mail');

    await tester.tap(find.byTooltip('Lock'));
    await settle(tester);
    expect(find.text('Mail'), findsNothing);
    await tester.enterText(find.byKey(vaultPasswordKey), 'wrong pass');
    await tester.tap(find.byKey(vaultGoKey));
    await until(
      tester,
      () => find.text('That is not the master password').evaluate().isNotEmpty,
    );
    await tester.enterText(find.byKey(vaultPasswordKey), 'master pass');
    await tester.tap(find.byKey(vaultGoKey));
    await until(tester, () => vault.state == VaultState.open);
    await settle(tester);
    expect(find.text('Mail'), findsOneWidget);
  });
}

/// Pumps in real time until [done], as a write a tap set going finishes
/// out of fake time's reach.
Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue);
}

/// Lets the database and the key's isolate finish, which fake time cannot,
/// and then the sheets' slides. Pumped rather than settled: a spinner
/// waiting on real time never settles in fake.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }
}
