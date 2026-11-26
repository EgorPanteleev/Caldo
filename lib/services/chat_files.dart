import 'dart:io';

import 'package:supabase/supabase.dart';

/// Private Storage objects shared by the app and the worker.
abstract final class ChatFiles {
  static const bucket = 'chat-files';
  static const largestFile = 50 * 1024 * 1024;

  /// A message stores a key relative to the account, never a URL or local path.
  static String? objectId(String chat, Object? key) {
    if (key is! String) return null;
    final parts = key.split('/');
    if (parts.length != 2 ||
        parts.first != chat ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(parts.last)) {
      return null;
    }
    return parts.last;
  }

  static Future<Map<String, Object?>> upload(
    SupabaseClient client,
    String key,
    File file, {
    required String name,
    required String mime,
    required int size,
    bool upsert = false,
  }) async {
    final user = client.auth.currentUser!.id;
    await client.storage
        .from(bucket)
        .upload(
          '$user/$key',
          file,
          fileOptions: FileOptions(contentType: mime, upsert: upsert),
        );
    return {'key': key, 'name': name, 'mime': mime, 'size': size};
  }
}
