#!/usr/bin/env bash
# Runs `caldo-mcp watch` as a systemd user service: this computer becomes
# one of the account's workers, running the agents the app's Agents tab
# asks for (in tmux), and tasks handed to a Claude model in Caldo are done
# by Claude here.
#
#   tool/mcp/watch.sh [watch options]   install (or reinstall) and start it
#   tool/mcp/watch.sh --remove          stop it and take it out
#
# Options go to `caldo-mcp watch` as they are, e.g. --dir ~/dev/src or
# --permission-mode acceptEdits, or --name desk for what the app calls it. Needs tool/mcp/install.sh and
# `caldo-mcp login` first. The service is given the PATH of the shell this
# is run from: a unit's own has no flutter, pnpm and the rest Claude may
# need. Logs: journalctl --user -u caldo-watch -f
set -euo pipefail

unit="$HOME/.config/systemd/user/caldo-watch.service"
slice="$HOME/.config/systemd/user/caldo-agents.slice"

if [[ "${1:-}" == --remove ]]; then
  systemctl --user disable --now caldo-watch.service 2>/dev/null || true
  rm -f "$unit" "$slice"
  systemctl --user daemon-reload
  echo "Removed caldo-watch."
  exit 0
fi

mcp="$HOME/.local/bin/caldo-mcp"
[[ -x "$mcp" ]] || { echo "Run tool/mcp/install.sh first." >&2; exit 1; }
"$mcp" status >/dev/null || { echo "Run caldo-mcp login first." >&2; exit 1; }
command -v claude >/dev/null || { echo "No claude on the PATH." >&2; exit 1; }
command -v tmux >/dev/null ||
  echo "No tmux: tasks will still be done, but the Agents tab can't run chats here." >&2

agent_scope=
if systemd-run --user --scope --quiet --collect --expand-environment=no \
    --property=OOMPolicy=stop -- true; then
  agent_scope=Environment=CALDO_AGENT_SLICE=caldo-agents.slice
else
  echo "Could not start a systemd user scope. Agent memory limits are unavailable." >&2
fi

args=""
for a in "$@"; do args+=" $(printf '%q' "$a")"; done

mkdir -p "$(dirname "$unit")"
cat > "$slice" <<'UNIT'
[Unit]
Description=Caldo agent chats and their tools

[Slice]
# A hard limit only. MemoryHigh (45%) was tried: with swap capped, the
# kernel could only throttle above it, and everything in the slice stalled
# (64 minutes fully stalled in two hours, a chat 7s to start). At the
# limit one agent's scope is stopped (OOMPolicy=stop) instead.
# Percentages refer to physical RAM.
MemoryMax=65%
MemorySwapMax=1G
UNIT

cat > "$unit" <<UNIT
[Unit]
Description=Caldo: hand Claude the tasks handed to it in the app
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h
ExecStart=$mcp watch$args
Restart=on-failure
RestartSec=30
# Keep the tmux server and chat wrappers for reattachment after restart.
KillMode=process
$agent_scope
Environment="PATH=$HOME/.local/bin:$PATH"

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable caldo-watch.service
systemctl --user restart caldo-watch.service
echo "caldo-watch is running. Logs: journalctl --user -u caldo-watch -f"
