#!/usr/bin/env python3
"""Draws the grain laid over task cards (assets/grain.png).

White, with the grain in the alpha: plain noise around half, one value a
pixel and nothing blurred, since the card lays one pixel of it on each of
the screen's (`TaskCard.grainOver`). Larger and softened grains were
tried and read as noise; this one was picked from pictures ("fine", then
level 2). The alpha keeps its full range and the depth is set where it is
drawn.

Rerun after changing it: python3 tool/make_grain.py
"""

import numpy as np
from PIL import Image

SIZE = 256

rng = np.random.default_rng(11)
alpha = np.clip(0.5 + 0.22 * rng.normal(size=(SIZE, SIZE)), 0, 1)

rgba = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
rgba[..., :3] = 255
rgba[..., 3] = np.round(alpha * 255).astype(np.uint8)
Image.fromarray(rgba, 'RGBA').save('assets/grain.png', optimize=True)
