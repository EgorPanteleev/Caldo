#!/usr/bin/env bash
# Builds Caldo's MCP server and puts it on the PATH as `caldo-mcp`.
#
# A kernel snapshot run by the Dart VM that ships with Flutter: it starts in
# a tenth of a second, where `dart run` compiles first, and it keeps working
# while the source tree is mid-edit. (`dart compile exe` refuses packages
# with build hooks, and sqlite3 has one.) Rerun after changing lib/mcp.
set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
opt="$HOME/.local/opt/caldo-mcp"
bin="$HOME/.local/bin"
flutter="$(dirname "$(readlink -f "$(command -v flutter)")")"
dart="$flutter/cache/dart-sdk/bin/dart"

mkdir -p "$opt" "$bin"
(cd "$here" && "$dart" compile kernel bin/caldo_mcp.dart -o "$opt/caldo-mcp.dill.next")
mv "$opt/caldo-mcp.dill.next" "$opt/caldo-mcp.dill"

cat > "$bin/caldo-mcp" <<SH
#!/bin/sh
exec "$dart" "$opt/caldo-mcp.dill" "\$@"
SH
chmod +x "$bin/caldo-mcp"
# Agents wait on it for memory before builds, tests and emulators.
install -m 755 "$here/tool/mcp/room.sh" "$bin/caldo-room"

echo "Installed $bin/caldo-mcp."

# Registered with Claude and Codex, so either run anywhere has Caldo's
# tools — update_project_info among them — and Caldo's chats know which
# chat they are (CALDO_CHAT). Left as it is where one is there already.
if command -v claude >/dev/null && ! claude mcp get caldo >/dev/null 2>&1; then
  claude mcp add --scope user caldo -- "$bin/caldo-mcp" >/dev/null &&
    echo "Registered with Claude."
fi
if command -v codex >/dev/null && ! codex mcp get caldo >/dev/null 2>&1; then
  # Written by hand: `codex mcp add` can't name the variables Codex passes
  # on (env_vars), nor let message_chat wait past its 60s.
  config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  mkdir -p "$(dirname "$config")"
  {
    [ -s "$config" ] && echo
    echo '[mcp_servers.caldo]'
    echo "command = \"$bin/caldo-mcp\""
    echo 'env_vars = ["CALDO_CHAT"]'
    echo 'tool_timeout_sec = 7260'
  } >> "$config"
  echo "Registered with Codex."
fi
echo "Next, if not signed in yet: caldo-mcp login"
