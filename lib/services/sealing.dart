import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// How hard a master password is made to turn into a key: Argon2id, with
/// this much memory (KiB), this many passes and this many lanes.
///
/// Kept with the vault rather than built in, so a vault made with one
/// setting still opens after the next is raised.
class Kdf {
  final int memory;
  final int iterations;
  final int lanes;

  const Kdf({required this.memory, required this.iterations, this.lanes = 1});

  /// RFC 9106's second recommendation: 64 MiB, three passes. The server
  /// keeps the vault's key sealed with the password, so the password is
  /// all that stands between a copy of the server and the secrets; this is
  /// about a second on a phone, once per unlock by password.
  static const strong = Kdf(memory: 64 * 1024, iterations: 3);

  /// For tests, which make vaults by the dozen.
  static const quick = Kdf(memory: 256, iterations: 1);

  String toJson() =>
      jsonEncode({'alg': 'argon2id', 'm': memory, 't': iterations, 'p': lanes});

  factory Kdf.fromJson(String text) {
    final json = jsonDecode(text) as Map<String, Object?>;
    if (json['alg'] != 'argon2id') {
      throw FormatException('Unknown key derivation ${json['alg']}');
    }
    return Kdf(
      memory: json['m'] as int,
      iterations: json['t'] as int,
      lanes: json['p'] as int,
    );
  }
}

/// The few things the vault does with cryptography, and nothing else:
/// a key from a password, and a sealed box that says whether it was
/// tampered with. AES-256-GCM throughout, with a fresh random nonce for
/// every box.
///
/// Pure Dart (pointycastle), so the phone and the desktop seal alike and a
/// box sealed on one opens on the other.
abstract final class Sealing {
  static final _random = Random.secure();

  static const keyLength = 32;
  static const _nonceLength = 12;

  static Uint8List randomBytes(int n) =>
      Uint8List.fromList([for (var i = 0; i < n; i++) _random.nextInt(256)]);

  /// A random (version 4) uuid, for a row the database must not name for
  /// itself: a secret's uuid is sealed into it before it is written.
  static String uuid() {
    final b = randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = [for (final x in b) x.toRadixString(16).padLeft(2, '0')];
    return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
        '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
        '${hex.sublist(10).join()}';
  }

  /// The key [password] makes with [salt]. On an isolate of its own: it
  /// takes the better part of a second, on purpose, and the screen should
  /// not stop while it does.
  static Future<Uint8List> derive(String password, Uint8List salt, Kdf kdf) =>
      Isolate.run(() => deriveNow(password, salt, kdf));

  static Uint8List deriveNow(String password, Uint8List salt, Kdf kdf) {
    final generator = Argon2BytesGenerator()
      ..init(
        Argon2Parameters(
          Argon2Parameters.ARGON2_id,
          salt,
          desiredKeyLength: keyLength,
          iterations: kdf.iterations,
          memory: kdf.memory,
          lanes: kdf.lanes,
        ),
      );
    final out = Uint8List(keyLength);
    final bytes = Uint8List.fromList(utf8.encode(password));
    generator.deriveKey(bytes, 0, out, 0);
    return out;
  }

  /// [plain] sealed with [key]: the nonce, then the ciphertext and its tag.
  /// [bound] is not sealed but is checked on opening — the uuid of the row
  /// the box belongs to, so a box moved into another row will not open.
  static Uint8List seal(Uint8List key, List<int> plain, {String bound = ''}) {
    final nonce = randomBytes(_nonceLength);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, _params(key, nonce, bound));
    final sealed = cipher.process(Uint8List.fromList(plain));
    return Uint8List.fromList([...nonce, ...sealed]);
  }

  /// What [box] holds, or null if [key] is not the one it was sealed with,
  /// or anything in it or [bound] has changed since.
  static Uint8List? open(Uint8List key, Uint8List box, {String bound = ''}) {
    if (box.length < _nonceLength + 16) return null;
    final nonce = box.sublist(0, _nonceLength);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, _params(key, nonce, bound));
    try {
      return cipher.process(box.sublist(_nonceLength));
    } on InvalidCipherTextException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static AEADParameters<KeyParameter> _params(
    Uint8List key,
    Uint8List nonce,
    String bound,
  ) => AEADParameters(
    KeyParameter(key),
    128,
    nonce,
    Uint8List.fromList(utf8.encode(bound)),
  );

  static String sealText(Uint8List key, String text, {String bound = ''}) =>
      base64Encode(seal(key, utf8.encode(text), bound: bound));

  static String? openText(Uint8List key, String box, {String bound = ''}) {
    final Uint8List bytes;
    try {
      bytes = base64Decode(box);
    } on FormatException {
      return null;
    }
    final plain = open(key, bytes, bound: bound);
    return plain == null ? null : utf8.decode(plain, allowMalformed: true);
  }
}
