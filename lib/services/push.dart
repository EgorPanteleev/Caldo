import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase/supabase.dart';

import '../l10n/strings.dart';
import '../utils/platform.dart';

/// The Agents tab's notifications on the phone (`Push.kt`): a chat waiting
/// on the user, or its agent's own word, pushed by the Edge Function
/// `push` through Firebase.
///
/// All this side does is keep the phone's token on the server while signed
/// in (`push_tokens`), and say which chat is on screen, so it isn't told of
/// itself. The worker and the MCP server ask for the pushes; Kotlin draws
/// them, with the app open or not. Not on the desktop: Firebase doesn't
/// reach Linux.
class Push {
  Push._();

  static const _channel = MethodChannel('caldo/push');

  static SupabaseClient? _client;
  static String? _token;

  /// Signed in on [client]: this phone's token kept for the account, and
  /// again whenever Firebase renews it.
  static Future<void> signedIn(SupabaseClient client) async {
    if (onDesktop) return;
    _client = client;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'token') await _keep(call.arguments);
    });
    try {
      await _keep(
        await _channel.invokeMethod<Object?>('token', {
          'name': S.current.agentsChannel,
          'hint': S.current.agentsChannelHint,
        }),
      );
    } on MissingPluginException {
      // No activity: the widget's engine, or a test.
    } catch (e) {
      // Offline, or a server without the table: kept on the next sign-in
      // or opening.
      debugPrint('Push token not kept: $e');
    }
  }

  static Future<void> _keep(Object? answer) async {
    final client = _client;
    if (answer is! Map || client == null) return;
    final token = answer['token'];
    if (token is! String || token.isEmpty) return;
    await client.rpc(
      'keep_push_token',
      params: {'token': token, 'device': answer['device']},
    );
    _token = token;
  }

  /// About to sign out of [client]: this phone's token let go of while the
  /// session can still say so. A session ended elsewhere can't; the phone
  /// then drops what comes for it (`Push.show`).
  static Future<void> signingOut(SupabaseClient? client) async {
    final token = _token;
    _client = null;
    _token = null;
    if (token == null || client == null) return;
    try {
      await client.from('push_tokens').delete().eq('token', token);
    } catch (_) {
      // Unreachable: the token stays until a push to it finds it signed
      // out, or another account takes it.
    }
  }

  static String? _looking;

  /// [chat] on screen, or none for null: it isn't told of itself, and what
  /// it had said on the phone is taken down.
  static void looking(String? chat) {
    if (onDesktop) return;
    _looking = chat;
    unawaited(
      _channel.invokeMethod<void>('looking', chat).catchError((Object _) {}),
    );
  }

  /// [chat]'s screen closed: unless another has come up over it since.
  static void left(String chat) {
    if (_looking == chat) looking(null);
  }
}
