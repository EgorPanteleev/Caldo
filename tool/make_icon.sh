#!/bin/sh
# Draws the launcher icon from assets/icon/src into every size Android asks
# for: the legacy square at each density, and the three layers of the
# adaptive icon (background, foreground, and the one-colour layer Android 13
# themes). Needs rsvg-convert. Run from the repository root after editing an
# SVG; the PNGs it writes are checked in.
set -e
SRC=assets/icon/src
RES=android/app/src/main/res

rsvg-convert -w 1024 -h 1024 $SRC/caldo.svg -o assets/icon/ic_launcher.png

# The legacy icon is 48dp; an adaptive layer is 108dp, of which the launcher
# shows the middle 72.
for d in mdpi:48:108 hdpi:72:162 xhdpi:96:216 xxhdpi:144:324 xxxhdpi:192:432; do
  name=${d%%:*}; rest=${d#*:}; legacy=${rest%%:*}; layer=${rest#*:}
  mkdir -p $RES/mipmap-$name $RES/drawable-$name
  rsvg-convert -w $legacy -h $legacy $SRC/caldo.svg \
    -o $RES/mipmap-$name/ic_launcher.png
  rsvg-convert -w $layer -h $layer $SRC/caldo_fg.svg \
    -o $RES/drawable-$name/ic_launcher_foreground.png
  rsvg-convert -w $layer -h $layer $SRC/ic_bg.svg \
    -o $RES/drawable-$name/ic_launcher_background.png
  rsvg-convert -w $layer -h $layer $SRC/caldo_mono.svg \
    -o $RES/drawable-$name/ic_launcher_monochrome.png
done
