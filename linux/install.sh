#!/bin/sh
# Puts this copy of Caldo among the user's own programs — no root, nothing
# outside their home — and tells the desktop about it: the program under
# ~/.local/opt/caldo, where it can replace itself when a newer release is
# out, a `caldo` on the path, an entry among the applications, and the icon
# that entry and the window wear. Run it again to install a newer copy over
# an older one. What Caldo holds is kept elsewhere
# (~/.local/share/com.igor.caldo) and is not touched.
#
#   ./install.sh              install
#   ./install.sh --uninstall  take the program out again, leaving the tasks
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
OPT=${CALDO_PREFIX:-$HOME/.local/opt}/caldo
BIN=$HOME/.local/bin
ENTRY=$DATA/applications/com.igor.caldo.desktop
ICONS=$DATA/icons/hicolor

refresh() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t "$ICONS" >/dev/null 2>&1 || true
  fi
}

if [ "$1" = "--uninstall" ]; then
  rm -rf "$OPT"
  rm -f "$BIN/caldo" "$ENTRY" \
    "$ICONS/scalable/apps/com.igor.caldo.svg" \
    "$ICONS/256x256/apps/com.igor.caldo.png"
  refresh
  echo "Caldo is uninstalled. Your tasks are still in $DATA/com.igor.caldo."
  exit 0
fi

if [ ! -x "$HERE/caldo" ] || [ ! -d "$HERE/data" ]; then
  echo "install.sh must sit beside the caldo program it installs." >&2
  exit 1
fi

if [ "$HERE" != "$OPT" ]; then
  mkdir -p "$(dirname "$OPT")"
  # Beside the old one and then swapped in by name, so a copy cut short
  # leaves the old one whole.
  rm -rf "$OPT.new"
  cp -r "$HERE" "$OPT.new"
  rm -rf "$OPT"
  mv "$OPT.new" "$OPT"
fi

mkdir -p "$BIN" "$DATA/applications" \
  "$ICONS/scalable/apps" "$ICONS/256x256/apps"
ln -sf "$OPT/caldo" "$BIN/caldo"
cp "$OPT/data/caldo.svg" "$ICONS/scalable/apps/com.igor.caldo.svg"
cp "$OPT/data/caldo.png" "$ICONS/256x256/apps/com.igor.caldo.png"
# By its full path: ~/.local/bin is not on every desktop's path.
sed "s|^Exec=.*|Exec=\"$OPT/caldo\"|" "$OPT/data/com.igor.caldo.desktop" \
  > "$ENTRY"
refresh
echo "Caldo is installed in $OPT."
