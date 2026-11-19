#!/usr/bin/env python3
"""Draws the grain laid over task cards (assets/grain.png).

White, with the grain in the alpha: noise around half, softened a little
so a grain is about a point across rather than a single hard pixel, and
blurred round the edges so the tile repeats without a seam. The card lays
it at a few percent (`TaskCard`), so the alpha here keeps its full range
and the depth is set where it is drawn.

Rerun after changing it: python3 tool/make_grain.py
"""

import numpy as np
from PIL import Image

SIZE = 128

rng = np.random.default_rng(7)
noise = rng.normal(size=(SIZE, SIZE))
# A 3×3 blur that wraps, so the tile's right edge meets its left.
soft = sum(
    np.roll(np.roll(noise, dy, 0), dx, 1) * w
    for dy, dx, w in [
        (0, 0, 4), (0, 1, 2), (0, -1, 2), (1, 0, 2), (-1, 0, 2),
        (1, 1, 1), (1, -1, 1), (-1, 1, 1), (-1, -1, 1),
    ]
) / 16
soft /= soft.std()
alpha = np.clip(0.5 + 0.22 * soft, 0, 1)

rgba = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
rgba[..., :3] = 255
rgba[..., 3] = np.round(alpha * 255).astype(np.uint8)
Image.fromarray(rgba, 'RGBA').save('assets/grain.png', optimize=True)
