#!/usr/bin/env python3
"""Draws the grain laid over task cards (assets/grain.png).

White, with the grain in the alpha: noise around half, blurred so a grain
is a soft fleck a few pixels across rather than a single hard one, the
blur wrapping round the edges so the tile repeats without a seam. The
card lays it at a few percent (`TaskCard`), so the alpha here keeps its full range
and the depth is set where it is drawn.

Rerun after changing it: python3 tool/make_grain.py
"""

import numpy as np
from PIL import Image

SIZE = 128

rng = np.random.default_rng(7)
noise = rng.normal(size=(SIZE, SIZE))
# A Gaussian blur that wraps, so the tile's right edge meets its left.
# Blurred enough that the grain reads as frost rather than sand (asked
# for "a bit blur" over the first, 3×3-softened grain); scaled back to
# its full range after, so blurring softens it without fading it.
SIGMA = 1.1
r = 4
taps = [
    (dy, dx, np.exp(-(dy * dy + dx * dx) / (2 * SIGMA * SIGMA)))
    for dy in range(-r, r + 1)
    for dx in range(-r, r + 1)
]
soft = sum(np.roll(np.roll(noise, dy, 0), dx, 1) * w for dy, dx, w in taps)
soft /= soft.std()
alpha = np.clip(0.5 + 0.22 * soft, 0, 1)

rgba = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
rgba[..., :3] = 255
rgba[..., 3] = np.round(alpha * 255).astype(np.uint8)
Image.fromarray(rgba, 'RGBA').save('assets/grain.png', optimize=True)
