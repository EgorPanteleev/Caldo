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

echo "Installed $bin/caldo-mcp."
echo "Next: caldo-mcp login, then"
echo "  claude mcp add --scope user caldo -- $bin/caldo-mcp"
