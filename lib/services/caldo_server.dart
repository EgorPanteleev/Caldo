/// Where Caldo's sync server is and how an account is named there.
///
/// Apart from [Account] and free of Flutter: the MCP server
/// (`bin/caldo_mcp.dart`) runs on plain Dart and signs in to the same place
/// the same way.
abstract final class CaldoServer {
  /// Caldo's project on Supabase's cloud, unless a device is pointed
  /// elsewhere in Settings — a local Supabase on this PC, which the emulator
  /// and the desktop reach at different addresses.
  static const url = String.fromEnvironment(
    'CALDO_SYNC_URL',
    defaultValue: 'https://eqgczddzmvmczwcgbenr.supabase.co',
  );

  /// The server's public key: it only says which project a request is for,
  /// and every row is guarded by who is signed in, not by this.
  static const _key = String.fromEnvironment(
    'CALDO_SYNC_KEY',
    defaultValue: 'sb_publishable_UifMTJoD6l7uP40ZtL8aAA_2zk9ot27',
  );

  /// The key every local Supabase is started with, for any other address.
  static const _localKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwi'
      'cm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnW'
      'NReilDMblYTn_I0';

  /// The public key for the server at [address].
  static String keyFor(String address) => address == url ? _key : _localKey;

  /// The domain a name is kept under. `.invalid` is reserved never to
  /// resolve, so nothing could ever be mailed to one by mistake.
  static const _domain = '@caldo.invalid';

  /// The address Auth knows the name [name] by.
  static String loginOf(String name) => name.trim().toLowerCase() + _domain;

  /// The name in a login, or the login itself for an account made by email.
  static String nameIn(String login) => login.endsWith(_domain)
      ? login.substring(0, login.length - _domain.length)
      : login;
}
