#!/bin/sh
# Draws the launcher icons from assets/icon/src into every size Android asks
# for: the legacy square at each density, and the two drawn layers of the
# adaptive icon. There are two icons (LauncherIcon.kt says which a phone
# gets): caldo*, the header and rings over the page's colour
# (@color/ic_launcher_page), so the page fills the launcher's shape; and
# caldo_free*, the whole page on a transparent ground, for Samsung. Needs
# rsvg-convert. Run from the repository root after editing an SVG; the PNGs
# it writes are checked in.
set -e
SRC=assets/icon/src
RES=android/app/src/main/res

rsvg-convert -w 1024 -h 1024 $SRC/caldo.svg -o assets/icon/ic_launcher.png

# The legacy icon is 48dp; an adaptive layer is 108dp, of which the launcher
# shows the middle 72.
for d in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  name=${d%%:*}; rest=${d#*:}; legacy=${rest%%:*}; layer=${rest#*:}
  mkdir -p $RES/mipmap-$name $RES/drawable-$name
  for icon in "" _free; do
    rsvg-convert -w $legacy -h $legacy $SRC/caldo$icon.svg \
      -o $RES/mipmap-$name/ic_launcher$icon.png
    rsvg-convert -w $layer -h $layer $SRC/caldo${icon}_fg.svg \
      -o $RES/drawable-$name/ic_launcher${icon}_foreground.png
    rsvg-convert -w $layer -h $layer $SRC/caldo${icon}_mono.svg \
      -o $RES/drawable-$name/ic_launcher${icon}_monochrome.png
  done
done
