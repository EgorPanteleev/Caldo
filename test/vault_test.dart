import 'dart:convert';
import 'dart:math';

import 'package:caldo/db/database.dart';
import 'package:caldo/db/sync_store.dart';
import 'package:caldo/models/secret.dart';
import 'package:caldo/providers/vault_provider.dart';
import 'package:caldo/services/sealing.dart';
import 'package:caldo/services/sync.dart';
import 'package:caldo/widgets/vault_sheets.dart' show makePassword;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fake_server.dart';
import 'support/test_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initTestDatabase);

  group('sealing', () {
    final key = Sealing.randomBytes(Sealing.keyLength);

    test('a box opens with its key and its row, and nothing else', () {
      final box = Sealing.sealText(key, 'hunter2', bound: 'row-1');
      expect(Sealing.openText(key, box, bound: 'row-1'), 'hunter2');
      expect(Sealing.openText(key, box, bound: 'row-2'), isNull);
      final other = Sealing.randomBytes(Sealing.keyLength);
      expect(Sealing.openText(other, box, bound: 'row-1'), isNull);
    });

    test('a box altered by one bit no longer opens', () {
      final box = base64Decode(Sealing.sealText(key, 'hunter2'));
      box[box.length - 20] ^= 1;
      expect(Sealing.open(key, box), isNull);
    });

    test('the same text seals differently every time', () {
      expect(
        Sealing.sealText(key, 'hunter2'),
        isNot(Sealing.sealText(key, 'hunter2')),
      );
    });

    test('Argon2id gives the RFC 9106 answer', () {
      // RFC 9106's test vector needs a secret and associated data, which
      // the vault does not use; this one is checked against the reference
      // implementation (`argon2 somesalt -id -t 2 -m 16 -p 1 -l 32`).
      final out = Sealing.deriveNow(
        'password',
        utf8.encode('somesalt'),
        const Kdf(memory: 65536, iterations: 2),
      );
      expect(
        out.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7',
      );
    });

    test('the key setting is kept with the vault and read back', () {
      final kdf = Kdf.fromJson(Kdf.strong.toJson());
      expect(kdf.memory, 64 * 1024);
      expect(kdf.iterations, 3);
      expect(kdf.lanes, 1);
    });
  });

  group('the vault', () {
    late AppDatabase db;
    late VaultProvider vault;

    Future<VaultProvider> open(AppDatabase on) async {
      final v = VaultProvider(db: on, kdf: Kdf.quick);
      await v.start();
      return v;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase('$dir/vault.db');
      db = AppDatabase.named('vault.db');
      vault = await open(db);
    });

    tearDown(() async {
      vault.dispose();
      await db.close();
    });

    const mail = Secret(
      title: 'Mail',
      login: 'egor@example.com',
      password: 'correct horse battery staple',
      fields: [SecretField(name: 'PIN', value: '0451', hidden: true)],
    );

    test('starts with no vault, and one made is open', () async {
      expect(vault.state, VaultState.none);
      await vault.create('master pass');
      expect(vault.state, VaultState.open);
      expect(vault.secrets, isEmpty);
    });

    test('nothing typed into a secret is written down as typed', () async {
      await vault.create('master pass');
      await vault.save(mail);
      final raw = jsonEncode([
        ...await db.getSecrets(),
        ...await db.getVaultKeys(),
      ]);
      for (final word in ['Mail', 'egor@', 'horse', '0451', 'master pass']) {
        expect(raw, isNot(contains(word)));
      }
    });

    test('locks, and opens again with the password only', () async {
      await vault.create('master pass');
      await vault.save(mail);
      vault.lock();
      expect(vault.state, VaultState.locked);
      expect(vault.secrets, isEmpty);
      expect(await vault.unlock('master pas'), isFalse);
      expect(vault.state, VaultState.locked);
      expect(await vault.unlock('master pass'), isTrue);
      final back = vault.secrets.single;
      expect(back.title, 'Mail');
      expect(back.password, 'correct horse battery staple');
      expect(back.fields.single.value, '0451');
      expect(back.fields.single.hidden, isTrue);
    });

    test('a vault already here is found locked on opening', () async {
      await vault.create('master pass');
      await vault.save(mail);
      final again = await open(db);
      addTearDown(again.dispose);
      expect(again.state, VaultState.locked);
      expect(await again.unlock('master pass'), isTrue);
      expect(again.secrets.single.title, 'Mail');
    });

    test('a changed secret keeps its place and its uuid', () async {
      await vault.create('master pass');
      final saved = await vault.save(mail);
      final changed = await vault.save(saved.copyWith(password: 'new one'));
      expect(changed.uuid, saved.uuid);
      expect(vault.secrets.single.password, 'new one');
      expect(await db.getSecrets(), hasLength(1));
    });

    test('secrets are listed by name, whatever the case', () async {
      await vault.create('master pass');
      for (final title in ['bank', 'Amazon', 'Car']) {
        await vault.save(Secret(title: title));
      }
      expect(vault.secrets.map((s) => s.title), ['Amazon', 'bank', 'Car']);
    });

    test(
      'a new master password opens it and the old one no longer does',
      () async {
        await vault.create('master pass');
        await vault.save(mail);
        expect(await vault.changePassword('wrong', 'newer pass'), isFalse);
        expect(await vault.changePassword('master pass', 'newer pass'), isTrue);
        vault.lock();
        expect(await vault.unlock('master pass'), isFalse);
        expect(await vault.unlock('newer pass'), isTrue);
        expect(vault.secrets.single.title, 'Mail');
      },
    );

    test('a deleted secret leaves a tombstone for the other devices', () async {
      await vault.create('master pass');
      final saved = await vault.save(mail);
      await vault.delete(saved);
      expect(vault.secrets, isEmpty);
      final graves = await (await db.database).query('tombstones');
      expect(graves.map((t) => t['uuid']), contains(saved.uuid));
    });

    test('deleting the vault leaves none, to start again', () async {
      await vault.create('master pass');
      await vault.save(mail);
      vault.lock();
      await vault.deleteVault();
      expect(vault.state, VaultState.none);
      expect(await db.getSecrets(), isEmpty);
      expect(await db.getVaultKeys(), isEmpty);
    });

    test('locks itself after the time away, and not before', () async {
      await vault.create('master pass');
      await vault.setLockAfter(1);
      vault.didChangeAppLifecycleState(AppLifecycleState.paused);
      vault.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(vault.state, VaultState.open);
      await vault.setLockAfter(0);
      vault.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(vault.state, VaultState.locked);
    });

    test(
      'a backup carries the vault sealed, and an older one leaves it be',
      () async {
        await vault.create('master pass');
        await vault.save(mail);
        final tables = await db.dump();
        expect(tables['secrets'], hasLength(1));
        expect(tables['vault_keys'], hasLength(1));

        // A backup from before there was a vault.
        await db.replaceAll({
          for (final t in ['lists', 'tasks', 'completions']) t: tables[t]!,
        });
        await vault.reload();
        expect(vault.secrets.single.title, 'Mail');

        // And this one, restored over a vault deleted since.
        await vault.deleteVault();
        await db.replaceAll(tables);
        await vault.reload();
        expect(vault.state, VaultState.locked);
        expect(await vault.unlock('master pass'), isTrue);
        expect(vault.secrets.single.title, 'Mail');
      },
    );
  });

  group('two devices', () {
    late FakeServer server;
    late AppDatabase a;
    late AppDatabase b;
    late Sync syncA;
    late Sync syncB;
    late VaultProvider vaultA;
    late VaultProvider vaultB;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final dir = await databaseFactory.getDatabasesPath();
      for (final name in ['va.db', 'vb.db']) {
        await databaseFactory.deleteDatabase('$dir/$name');
      }
      server = FakeServer();
      a = AppDatabase.named('va.db');
      b = AppDatabase.named('vb.db');
      syncA = Sync(SyncStore(a), server: server);
      syncB = Sync(SyncStore(b), server: server);
      vaultA = VaultProvider(db: a, kdf: Kdf.quick);
      vaultB = VaultProvider(db: b, kdf: Kdf.quick);
      await vaultA.start();
      await vaultB.start();
    });

    tearDown(() async {
      vaultA.dispose();
      vaultB.dispose();
      await a.close();
      await b.close();
    });

    test('the server keeps only sealed boxes, and the other phone opens '
        'them with the password', () async {
      await vaultA.create('master pass');
      final saved = await vaultA.save(
        const Secret(title: 'Bank', password: 'swordfish'),
      );
      await syncA.run();
      final kept = jsonEncode(server.dataOf('secrets', saved.uuid!));
      expect(kept, isNot(contains('Bank')));
      expect(kept, isNot(contains('swordfish')));

      await syncB.run();
      await vaultB.reload();
      expect(vaultB.state, VaultState.locked);
      expect(await vaultB.unlock('master pass'), isTrue);
      expect(vaultB.secrets.single.password, 'swordfish');
    });

    test('a new master password reaches the other phone', () async {
      await vaultA.create('master pass');
      await vaultA.save(const Secret(title: 'Bank'));
      await syncA.run();
      await syncB.run();
      await vaultB.reload();
      expect(await vaultB.unlock('master pass'), isTrue);

      await vaultA.changePassword('master pass', 'newer pass');
      await syncA.run();
      await syncB.run();
      vaultB.lock();
      expect(await vaultB.unlock('master pass'), isFalse);
      expect(await vaultB.unlock('newer pass'), isTrue);
    });

    test('two vaults made apart become one on unlocking', () async {
      await vaultA.create('master pass');
      await vaultA.save(const Secret(title: 'From A'));
      await vaultB.create('master pass');
      await vaultB.save(const Secret(title: 'From B'));
      await syncA.run();
      await syncB.run();
      await syncA.run();

      // B has both keys now; unlocking opens both and keeps the older.
      vaultB.lock();
      expect(await vaultB.unlock('master pass'), isTrue);
      expect(vaultB.secrets.map((s) => s.title), ['From A', 'From B']);
      expect(await b.getVaultKeys(), hasLength(1));

      await syncB.run();
      await syncA.run();
      await vaultA.reload();
      expect(await a.getVaultKeys(), hasLength(1));
      expect(vaultA.secrets.map((s) => s.title), ['From A', 'From B']);
    });

    test('a vault under another password waits until it is given', () async {
      await vaultA.create('master pass');
      await vaultA.save(const Secret(title: 'From A'));
      await vaultB.create('other pass');
      await vaultB.save(const Secret(title: 'From B'));
      await syncB.run();
      await syncA.run();

      await vaultA.reload();
      expect(vaultA.secrets.map((s) => s.title), ['From A']);
      expect(vaultA.sealedElsewhere, 1);

      // Given to the open vault, it brings them in under this one's own
      // password, which goes on opening everything.
      expect(await vaultA.unlock('wrong pass'), isFalse);
      expect(await vaultA.unlock('other pass'), isTrue);
      expect(vaultA.secrets.map((s) => s.title), ['From A', 'From B']);
      expect(vaultA.sealedElsewhere, 0);
      expect(await a.getVaultKeys(), hasLength(1));
      vaultA.lock();
      expect(await vaultA.unlock('other pass'), isFalse);
      expect(await vaultA.unlock('master pass'), isTrue);
      expect(vaultA.secrets, hasLength(2));
    });
  });

  test('a made password is as long as asked, with every kind in it', () {
    final rng = Random(7);
    for (var i = 0; i < 200; i++) {
      final made = makePassword(length: 12, random: rng);
      expect(made, hasLength(12));
      expect(made, matches(RegExp(r'[a-z]')));
      expect(made, matches(RegExp(r'[A-Z]')));
      expect(made, matches(RegExp(r'[0-9]')));
      expect(made, matches(RegExp(r'[^a-zA-Z0-9]')));
    }
    expect(
      makePassword(length: 30, digits: false, symbols: false, random: rng),
      matches(RegExp(r'^[a-zA-Z]{30}$')),
    );
  });
}
