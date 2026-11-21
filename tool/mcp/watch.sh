#!/usr/bin/env bash
# Runs `caldo-mcp watch` as a systemd user service, so tasks put in Caldo's
# "Claude" group are handed to Claude on this computer.
#
#   tool/mcp/watch.sh [watch options]   install (or reinstall) and start it
#   tool/mcp/watch.sh --remove          stop it and take it out
#
# Options go to `caldo-mcp watch` as they are, e.g. --dir ~/dev/src or
# --permission-mode acceptEdits. Needs tool/mcp/install.sh and
# `caldo-mcp login` first. The service is given the PATH of the shell this
# is run from: a unit's own has no flutter, pnpm and the rest Claude may
# need. Logs: journalctl --user -u caldo-watch -f
set -euo pipefail

unit="$HOME/.config/systemd/user/caldo-watch.service"

if [[ "${1:-}" == --remove ]]; then
  systemctl --user disable --now caldo-watch.service 2>/dev/null || true
  rm -f "$unit"
  systemctl --user daemon-reload
  echo "Removed caldo-watch."
  exit 0
fi

mcp="$HOME/.local/bin/caldo-mcp"
[[ -x "$mcp" ]] || { echo "Run tool/mcp/install.sh first." >&2; exit 1; }
"$mcp" status >/dev/null || { echo "Run caldo-mcp login first." >&2; exit 1; }
command -v claude >/dev/null || { echo "No claude on the PATH." >&2; exit 1; }

args=""
for a in "$@"; do args+=" $(printf '%q' "$a")"; done

mkdir -p "$(dirname "$unit")"
cat > "$unit" <<UNIT
[Unit]
Description=Caldo: hand Claude the tasks in its group
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h
ExecStart=$mcp watch$args
Restart=on-failure
RestartSec=30
Environment="PATH=$HOME/.local/bin:$PATH"

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable caldo-watch.service
systemctl --user restart caldo-watch.service
echo "caldo-watch is running. Logs: journalctl --user -u caldo-watch -f"
