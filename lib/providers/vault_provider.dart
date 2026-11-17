import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database.dart';
import '../l10n/strings.dart';
import '../models/secret.dart';
import '../services/background.dart';
import '../services/sealing.dart';
import '../services/sync.dart';
import '../services/vault_device.dart';

enum VaultState {
  /// Not read yet.
  loading,

  /// There is no vault: none made here, and none come from a synced device.
  none,
  locked,
  open,
}

/// The vault: passwords and the like, sealed with a master password.
///
/// Every secret is sealed with the vault's key — 32 random bytes made with
/// the vault — and that key is sealed with one made from the master
/// password (Argon2id). Changing the password seals the same key afresh,
/// so nothing else has to change, on this device or any other. A
/// fingerprint opens a second copy of the key kept on this phone alone
/// (`VaultDevice`, `Vault.kt`).
///
/// Two devices that each made a vault before hearing of the other's end
/// up with two keys. Unlocking opens every key the password opens, and
/// moves the secrets of all but the oldest over to it; a key sealed with a
/// different password waits, its secrets counted in [sealedElsewhere],
/// until that password is given to the open vault ([unlock] again), when
/// they move over to the key already open — so the password in use here
/// is the one that goes on opening everything.
///
/// While open, the opened secrets are held here and nowhere else; locking
/// lets go of them and of the keys. It locks itself once the app has been
/// away for [lockAfter] minutes.
class VaultProvider extends ChangeNotifier with WidgetsBindingObserver {
  final AppDatabase _db;
  final VaultDevice _device;

  /// What a new vault, or a new master password, is sealed with.
  final Kdf kdf;

  VaultProvider({AppDatabase? db, VaultDevice? device, this.kdf = Kdf.strong})
    : _db = db ?? AppDatabase.instance,
      _device = device ?? VaultDevice.instance;

  static const _kLockAfter = 'vault_lock_after';
  static const _kFinger = 'vault_finger';
  static const _kFingerKey = 'vault_finger_key';

  /// What the vault's key unlocks to prove it is the vault's key.
  static const _proof = 'caldo vault';

  VaultState _state = VaultState.loading;
  VaultState get state => _state;

  /// The secrets, by name, while the vault is open.
  List<Secret> _secrets = const [];
  List<Secret> get secrets => _secrets;

  /// Secrets this device cannot open: sealed with a key whose password has
  /// not been given here.
  int _elsewhere = 0;
  int get sealedElsewhere => _elsewhere;

  /// Whether a synced device is being asked for its vault before one is
  /// made here.
  bool _looking = false;
  bool get looking => _looking;

  bool _fingerAvailable = false;
  bool get fingerAvailable => _fingerAvailable;

  /// Whether the fingerprint opens the vault on this phone.
  bool get fingerOn => _finger != null;
  String? _finger;
  String? _fingerKey;

  int _lockAfter = 1;

  /// Minutes away from the app before the vault locks; 0 for at once.
  int get lockAfter => _lockAfter;

  static const lockChoices = [0, 1, 5, 15, 60];

  /// The shortest master password taken. It is all that guards the
  /// server's copy, so a short one is turned down rather than warned of.
  static const shortest = 8;

  /// The opened keys, by uuid, and the one new secrets are sealed with.
  final _keys = <String, Uint8List>{};
  String? _primary;

  bool _started = false;

  /// A fingerprint prompt is up. Android pauses the app under the PIN's
  /// page, which is not the user going away.
  bool _asking = false;
  bool get asking => _asking;
  DateTime? _awayAt;

  /// Reads the vault for the first time: called by its screen, so the app
  /// does none of this until the vault is looked at.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    Background.changed.addListener(_changedOutside);
    final prefs = await SharedPreferences.getInstance();
    _lockAfter = prefs.getInt(_kLockAfter) ?? 1;
    _finger = prefs.getString(_kFinger);
    _fingerKey = prefs.getString(_kFingerKey);
    _fingerAvailable = await _device.fingerAvailable();
    await _read();
    if (_state == VaultState.none && Sync.instance.server?.account != null) {
      // Signed in: a vault made on another device is likely on its way,
      // and one made here meanwhile would be a second.
      _looking = true;
      notifyListeners();
      await Sync.instance.run();
      _looking = false;
      await _read();
    }
  }

  @override
  void dispose() {
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      Background.changed.removeListener(_changedOutside);
    }
    super.dispose();
  }

  void _changedOutside() => reload();

  /// Reads the vault's rows again, after a sync or a restore wrote them.
  Future<void> reload() async {
    if (_started) await _read();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_asking) return;
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _awayAt ??= DateTime.now();
        if (_lockAfter == 0) lock();
      case AppLifecycleState.resumed:
        final away = _awayAt;
        _awayAt = null;
        if (away != null &&
            DateTime.now().difference(away) >= Duration(minutes: _lockAfter)) {
          lock();
        }
        _device.clearCopied();
        // A screen lock or a finger may have been set up meanwhile.
        _device.fingerAvailable().then((on) {
          if (on == _fingerAvailable) return;
          _fingerAvailable = on;
          notifyListeners();
        });
      default:
    }
  }

  /// Reads the keys and, while open, the secrets: after a sync or a restore
  /// has written either.
  Future<void> _read() async {
    final keys = await _db.getVaultKeys();
    final present = {for (final k in keys) k['uuid'] as String};
    _keys.removeWhere((uuid, _) => !present.contains(uuid));
    if (keys.isEmpty) {
      _lockNow(VaultState.none);
    } else if (_keys.isEmpty) {
      _lockNow(VaultState.locked);
    } else {
      // The key sealed with until now, unless it has been merged away
      // elsewhere meanwhile; then the oldest of those open.
      final primary = _primary;
      if (primary == null || !_keys.containsKey(primary)) {
        _primary = keys
            .map((k) => k['uuid'] as String)
            .firstWhere(_keys.containsKey);
      }
      await _readSecrets();
      _state = VaultState.open;
    }
    if (_fingerKey != null && !present.contains(_fingerKey)) {
      await _forgetFinger();
    }
    notifyListeners();
  }

  Future<void> _readSecrets() async {
    final opened = <Secret>[];
    var elsewhere = 0;
    for (final row in await _db.getSecrets()) {
      final uuid = row['uuid'] as String;
      final key = _keys[row['key_id']];
      final text = key == null
          ? null
          : Sealing.openText(key, row['sealed'] as String, bound: uuid);
      if (text == null) {
        elsewhere++;
        continue;
      }
      opened.add(
        Secret.opened(
          text,
          uuid: uuid,
          createdAt: row['created_at'] as int,
          updatedAt: row['updated_at'] as int,
        ),
      );
    }
    opened.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    _secrets = opened;
    _elsewhere = elsewhere;
  }

  /// Makes a vault sealed with [password].
  Future<void> create(String password) async {
    final key = Sealing.randomBytes(Sealing.keyLength);
    final uuid = Sealing.uuid();
    final salt = Sealing.randomBytes(16);
    final wrapping = await Sealing.derive(password, salt, kdf);
    await _db.insertVaultKey({
      'uuid': uuid,
      'salt': base64Encode(salt),
      'kdf': kdf.toJson(),
      'wrapped': base64Encode(Sealing.seal(wrapping, key, bound: uuid)),
      'proof': Sealing.sealText(key, _proof, bound: uuid),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    _keys[uuid] = key;
    await _read();
    Sync.instance.soon();
  }

  /// Opens the vault with [password]; false if it opens nothing. Given to
  /// an open vault, it opens the keys that one could not, and brings in
  /// their secrets.
  Future<bool> unlock(String password) async {
    final opened = <String, Uint8List>{};
    for (final row in await _db.getVaultKeys()) {
      final uuid = row['uuid'] as String;
      if (_keys.containsKey(uuid)) continue;
      final key = await _openKey(row, password);
      if (key != null) opened[uuid] = key;
    }
    if (opened.isEmpty) return false;
    _keys.addAll(opened);
    await _read();
    await _merge();
    if (_fingerKey != null && _fingerKey != _primary) await _forgetFinger();
    notifyListeners();
    return true;
  }

  static Future<Uint8List?> _openKey(
    Map<String, Object?> row,
    String password,
  ) async {
    final uuid = row['uuid'] as String;
    final Kdf kdf;
    try {
      kdf = Kdf.fromJson(row['kdf'] as String);
    } on FormatException {
      return null;
    }
    final wrapping = await Sealing.derive(
      password,
      base64Decode(row['salt'] as String),
      kdf,
    );
    return Sealing.open(
      wrapping,
      base64Decode(row['wrapped'] as String),
      bound: uuid,
    );
  }

  /// Moves every secret sealed with an opened key other than the oldest
  /// over to the oldest, and lets the others go. A key with a secret that
  /// will not open is kept, so nothing is lost with it.
  Future<void> _merge() async {
    final into = _primary;
    if (into == null) return;
    final others = {..._keys.keys}..remove(into);
    if (others.isEmpty) return;
    final rows = await _db.getSecrets();
    final resealed = <String, String>{};
    final keep = <String>{};
    for (final row in rows) {
      final from = row['key_id'] as String;
      if (!others.contains(from)) continue;
      final uuid = row['uuid'] as String;
      final text = Sealing.openText(
        _keys[from]!,
        row['sealed'] as String,
        bound: uuid,
      );
      if (text == null) {
        keep.add(from);
      } else {
        resealed[uuid] = Sealing.sealText(_keys[into]!, text, bound: uuid);
      }
    }
    final from = others.difference(keep);
    if (from.isEmpty) return;
    await _db.mergeVaultKeys(
      from: from,
      into: into,
      resealed: {
        for (final row in rows)
          if (from.contains(row['key_id']) && resealed[row['uuid']] != null)
            row['uuid'] as String: resealed[row['uuid']]!,
      },
    );
    await _read();
    Sync.instance.soon();
  }

  Map<String, String> get _promptWords => {
    'title': S.current.vaultPromptTitle,
    'cancel': S.current.cancel,
  };

  /// Opens the vault by fingerprint.
  Future<void> unlockWithFinger() async {
    final box = _finger;
    final uuid = _fingerKey;
    if (box == null || uuid == null) {
      throw const FingerException(FingerProblem.gone);
    }
    final Uint8List key;
    _asking = true;
    try {
      key = await _device.openWithFinger(base64Decode(box), _promptWords);
    } on FingerException catch (e) {
      if (e.problem == FingerProblem.gone) await _forgetFinger();
      rethrow;
    } finally {
      _asking = false;
    }
    // The key it gave back still has to be this vault's: the vault may
    // have been deleted, or replaced by a restore, since.
    final row = (await _db.getVaultKeys())
        .where((k) => k['uuid'] == uuid)
        .firstOrNull;
    if (row == null ||
        Sealing.openText(key, row['proof'] as String, bound: uuid) != _proof) {
      await _forgetFinger();
      notifyListeners();
      throw const FingerException(FingerProblem.gone);
    }
    _keys[uuid] = key;
    await _read();
  }

  /// Lets the fingerprint open the vault on this phone, or stops it.
  Future<void> setFinger(bool on) async {
    if (!on) {
      await _forgetFinger();
      notifyListeners();
      return;
    }
    final uuid = _primary;
    if (uuid == null) return;
    _asking = true;
    final Uint8List box;
    try {
      box = await _device.sealWithFinger(_keys[uuid]!, _promptWords);
    } finally {
      _asking = false;
    }
    final prefs = await SharedPreferences.getInstance();
    _finger = base64Encode(box);
    _fingerKey = uuid;
    await prefs.setString(_kFinger, _finger!);
    await prefs.setString(_kFingerKey, uuid);
    notifyListeners();
  }

  Future<void> _forgetFinger() async {
    if (_finger == null && _fingerKey == null) return;
    _finger = null;
    _fingerKey = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kFinger);
    await prefs.remove(_kFingerKey);
    await _device.forgetFinger();
  }

  Future<void> setLockAfter(int minutes) async {
    _lockAfter = minutes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLockAfter, minutes);
    notifyListeners();
  }

  /// Seals the vault's key afresh with [next]; false if [current] is not
  /// the master password. The key stays what it was, so every secret, and
  /// the fingerprint, go on opening as before.
  Future<bool> changePassword(String current, String next) async {
    final uuid = _primary;
    if (uuid == null) return false;
    final row = (await _db.getVaultKeys())
        .where((k) => k['uuid'] == uuid)
        .firstOrNull;
    if (row == null || await _openKey(row, current) == null) return false;
    final salt = Sealing.randomBytes(16);
    final wrapping = await Sealing.derive(next, salt, kdf);
    await _db.updateVaultKey(uuid, {
      'salt': base64Encode(salt),
      'kdf': kdf.toJson(),
      'wrapped': base64Encode(
        Sealing.seal(wrapping, _keys[uuid]!, bound: uuid),
      ),
    });
    Sync.instance.soon();
    return true;
  }

  void lock() {
    if (_state != VaultState.open) return;
    _lockNow(VaultState.locked);
    notifyListeners();
  }

  void _lockNow(VaultState state) {
    _keys.clear();
    _primary = null;
    _secrets = const [];
    _elsewhere = 0;
    _state = state;
  }

  /// Writes [secret], sealed, and gives it back as written.
  Future<Secret> save(Secret secret) async {
    final key = _primary;
    if (key == null) throw StateError('The vault is locked');
    final uuid = secret.uuid ?? Sealing.uuid();
    final createdAt = secret.uuid == null
        ? DateTime.now().millisecondsSinceEpoch
        : secret.createdAt;
    await _db.putSecret(
      uuid: uuid,
      keyId: key,
      sealed: Sealing.sealText(_keys[key]!, secret.seal(), bound: uuid),
      createdAt: createdAt,
    );
    await _read();
    Sync.instance.soon();
    return _secrets.firstWhere(
      (s) => s.uuid == uuid,
      orElse: () => secret.copyWith(uuid: uuid, createdAt: createdAt),
    );
  }

  Future<void> delete(Secret secret) async {
    final uuid = secret.uuid;
    if (uuid == null) return;
    await _db.deleteSecret(uuid);
    await _read();
    Sync.instance.soon();
  }

  /// Deletes the whole vault — for a master password forgotten, which
  /// nothing else can get past.
  Future<void> deleteVault() async {
    await _db.deleteVault();
    await _forgetFinger();
    await _read();
    Sync.instance.soon();
  }
}
