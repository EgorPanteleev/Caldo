#!/bin/sh
# caldo-room GB [command…] — waits until GB of memory is free, then runs
# the command. Agents share one 13 GB machine: builds, tests and emulators
# started side by side ran it out of memory and swap, and systemd-oomd
# killed the worker with every chat in it (2026-11-25).
#
# Free is the least of the machine's MemAvailable and the room left under
# every memory limit above this process (caldo-agents.slice caps agents at
# 65%). One check at a time, and the next waits until the command started
# has had a while to take what it needs, so two agents never both see the
# same free memory.
#
# Waits at most CALDO_ROOM_WAIT seconds (default 540, under a tool call's
# ten minutes), then exits 75 saying so: run it again.
set -eu

need=${1:?usage: caldo-room GB [command…]}
shift
wait_for=${CALDO_ROOM_WAIT:-540}
settle=${CALDO_ROOM_SETTLE:-30}

# Free memory in MiB.
room() {
  free=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
  group=$(sed -n 's/^0:://p' /proc/self/cgroup)
  while [ -n "$group" ] && [ "$group" != / ]; do
    dir=/sys/fs/cgroup$group
    if [ -r "$dir/memory.max" ] && [ "$(cat "$dir/memory.max")" != max ]; then
      left=$((($(cat "$dir/memory.max") - $(cat "$dir/memory.current")) / 1048576))
      [ "$left" -lt "$free" ] && free=$left
    fi
    group=${group%/*}
  done
  echo "$free"
}

lock=${XDG_RUNTIME_DIR:-/tmp}/caldo-room.lock
exec 9>"$lock"
flock 9

start=$(date +%s)
told=
while :; do
  have=$(room)
  [ "$have" -ge $((need * 1024)) ] && break
  waited=$(($(date +%s) - start))
  if [ "$waited" -ge "$wait_for" ]; then
    echo "caldo-room: still only $((have / 1024)) GB free of the $need GB needed after ${waited}s; try again." >&2
    exit 75
  fi
  if [ -z "$told" ]; then
    echo "caldo-room: $((have / 1024)) GB free, $need GB needed; waiting." >&2
    told=1
  fi
  sleep 15
done
[ -n "$told" ] && echo "caldo-room: $((have / 1024)) GB free after $(($(date +%s) - start))s." >&2

[ $# -eq 0 ] && exit 0
"$@" 9>&- &
child=$!
# Stopped (a tool call's time ran out), it takes the command with it.
trap 'kill "$child" 2>/dev/null; wait "$child"; exit 143' TERM INT HUP
# Hold the turn until the command has taken its memory, unless it is done
# sooner.
waited=0
while [ "$waited" -lt "$settle" ] && kill -0 "$child" 2>/dev/null; do
  sleep 1
  waited=$((waited + 1))
done
flock -u 9
wait "$child"
