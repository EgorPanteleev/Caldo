import 'dart:async';

import 'package:flutter/services.dart';

import '../utils/platform.dart';

/// Why a fingerprint did not open the vault.
enum FingerProblem {
  /// Backed out of; nothing to say.
  cancelled,

  /// The phone's fingerprints have changed since it was set up, or the
  /// key was otherwise lost: it is not coming back, and the master password
  /// is needed to set it up again.
  gone,

  /// Anything else — too many tries, no screen lock any more.
  failed,
}

class FingerException implements Exception {
  final FingerProblem problem;
  final String? message;

  const FingerException(this.problem, [this.message]);

  @override
  String toString() => 'FingerException($problem, $message)';
}

/// What the vault asks of the device (`Vault.kt`): the fingerprint, keeping
/// the screen out of screenshots, and a clipboard that forgets.
///
/// A desktop has none of the fingerprint and the screen; it copies through
/// Flutter's own clipboard.
class VaultDevice {
  VaultDevice._();
  static final instance = VaultDevice._();

  static const _channel = MethodChannel('caldo/vault');

  /// How long a copied secret is left on the clipboard.
  static const clipboardFor = Duration(seconds: 30);

  /// Whether the vault can be opened by fingerprint here.
  Future<bool> fingerAvailable() async {
    if (onDesktop) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// [key] sealed by a fingerprint shown now, for [open] to give back.
  Future<Uint8List> sealWithFinger(Uint8List key, Map<String, String> words) =>
      _ask('seal', {'key': key, 'words': words});

  /// The key [box] holds, once a fingerprint is shown.
  Future<Uint8List> openWithFinger(Uint8List box, Map<String, String> words) =>
      _ask('open', {'box': box, 'words': words});

  Future<Uint8List> _ask(String method, Map<String, Object> args) async {
    try {
      final answer = await _channel.invokeMethod<Uint8List>(method, args);
      if (answer == null) throw const FingerException(FingerProblem.failed);
      return answer;
    } on PlatformException catch (e) {
      throw FingerException(switch (e.code) {
        'cancelled' => FingerProblem.cancelled,
        'gone' => FingerProblem.gone,
        _ => FingerProblem.failed,
      }, e.message);
    } on MissingPluginException {
      throw const FingerException(FingerProblem.failed);
    }
  }

  /// Lets go of the fingerprint's key, as turning it off does.
  Future<void> forgetFinger() async {
    if (onDesktop) return;
    try {
      await _channel.invokeMethod<void>('forget');
    } on MissingPluginException {
      // Tests.
    }
  }

  bool _secure = false;

  /// Keeps the screen out of screenshots and the recent apps while [on].
  Future<void> secure(bool on) async {
    if (onDesktop || on == _secure) return;
    _secure = on;
    try {
      await _channel.invokeMethod<void>('secure', {'on': on});
    } on MissingPluginException {
      // Tests.
    }
  }

  /// What was last copied, until it has been taken off the clipboard again.
  String? _copied;
  Timer? _clear;

  /// Copies [text], and takes it off the clipboard again after
  /// [clipboardFor] if nothing else has been copied over it.
  Future<void> copy(String text) async {
    _copied = text;
    if (onDesktop) {
      await Clipboard.setData(ClipboardData(text: text));
    } else {
      try {
        await _channel.invokeMethod<void>('copy', {'text': text});
      } on MissingPluginException {
        await Clipboard.setData(ClipboardData(text: text));
      }
    }
    _clear?.cancel();
    _clear = Timer(clipboardFor, clearCopied);
  }

  /// Takes the last copied secret off the clipboard if it is still there
  /// and its time is up. Android will not show the clipboard to an app in
  /// the background, so it is asked again when the app comes back.
  Future<void> clearCopied() async {
    final text = _copied;
    if (text == null || (_clear?.isActive ?? false)) return;
    bool settled;
    if (onDesktop) {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == text) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
      settled = true;
    } else {
      try {
        settled =
            await _channel.invokeMethod<bool>('clearIf', {'text': text}) ??
            false;
      } on MissingPluginException {
        settled = true;
      }
    }
    if (settled) _copied = null;
  }
}
