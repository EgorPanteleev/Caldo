#!/bin/sh
# Builds Caldo for Linux and packs it the way a release carries it:
# release/Caldo-linux-x64.tar.gz, holding one directory, `caldo`, which is
# the program — its executable, the libraries and data beside it, and
# install.sh. Unpacked anywhere it runs as it is; ./caldo/install.sh puts it
# among the user's own programs. The name and the one directory are what
# the updater looks for (`Updates.linuxFile`, `Desktop.replaceWith`).
# Run from the repository root; anything given is handed to the build.
set -e
flutter build linux --release "$@"
mkdir -p release
# Without the map of native libraries the tests leave in the build: it
# names paths on this machine and nothing reads it once built.
tar -czf release/Caldo-linux-x64.tar.gz \
  -C build/linux/x64/release \
  --exclude=native_assets.json \
  --transform 's|^bundle|caldo|' bundle
ls -lh release/Caldo-linux-x64.tar.gz
