#!/bin/sh
# Runs the built Linux Caldo where it can be tried without touching the
# desk it is built at: on a display of its own (Xvfb, :99), with a home for
# its tasks and settings of its own, and a session bus of its own with a
# stand-in notification server on it (notifd.py). Nothing of the user's is
# read or written, and no window or notification of this one's reaches them.
#
#   tool/desktop/try.sh [name]     start it (stopping one already started)
#   tool/desktop/try.sh --stop     stop it, and the display
#
# Then look and poke:
#   import -display :99 -window root -crop 460x880+0+0 shot.png
#   python tool/desktop/x.py click 409 768
#
# What it holds is under $CALDO_TRY_DIR/<name> (default /tmp/caldo-try/run),
# the database at data/com.igor.caldo/caldo.db: stop it, seed tasks with
# sqlite3, and start it again. CALDO_BIN runs another copy than the build's
# — an installed one, to try an update on.
DIR=${CALDO_TRY_DIR:-/tmp/caldo-try}
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=${CALDO_BIN:-$HERE/../../build/linux/x64/release/bundle/caldo}

# By name, never by pattern (`pkill -f`): a pattern fits the command line of
# whatever shell is running this as readily as it fits the program, and
# stops that. The notification server goes with the app, below.
pkill -x caldo 2>/dev/null
if [ "$1" = "--stop" ]; then
  # This one's display and no other Xvfb that may be running.
  [ -f "$DIR/xvfb.pid" ] && kill "$(cat "$DIR/xvfb.pid")" 2>/dev/null
  rm -f "$DIR/xvfb.pid"
  exit 0
fi
sleep 1

HOME_OF_ITS_OWN=$DIR/${1:-run}
mkdir -p "$HOME_OF_ITS_OWN/data" "$HOME_OF_ITS_OWN/cache" "$HOME_OF_ITS_OWN/config"
export CALDO_TRY_DIR=$DIR
export XDG_DATA_HOME=$HOME_OF_ITS_OWN/data
export XDG_CACHE_HOME=$HOME_OF_ITS_OWN/cache
export XDG_CONFIG_HOME=$HOME_OF_ITS_OWN/config
export DISPLAY=:99 GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1
unset WAYLAND_DISPLAY

# With no pid on file there is nothing to ask after: `kill -0 ""` asks
# after this shell's own group, and is told it is running.
XVFB=$(cat "$DIR/xvfb.pid" 2>/dev/null)
if [ -z "$XVFB" ] || ! kill -0 "$XVFB" 2>/dev/null; then
  Xvfb :99 -screen 0 1300x1000x24 -nolisten tcp >"$DIR/xvfb.log" 2>&1 &
  echo $! >"$DIR/xvfb.pid"
  sleep 1
fi
# Line by line, or what the app prints waits in a buffer until it is shut.
nohup dbus-run-session -- sh -c \
  "python3 '$HERE/notifd.py' & sleep 0.7; stdbuf -oL -eL '$BIN'; kill %1" \
  >"$DIR/app.log" 2>&1 &
sleep 5
echo "Caldo is up on :99; its log is $DIR/app.log"
