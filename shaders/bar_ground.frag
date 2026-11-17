#version 460 core

// The blur under the tab bar: none at the top of the strip, growing row by
// row to its most at the foot. One direction a pass; the strip runs a
// horizontal pass and then a vertical one. A blur laid in bands of fixed
// strength left a visible step at every band's edge.

#include <flutter/runtime_effect.glsl>

precision highp float;

// Set by the engine: the size of what is under the strip, and it. The
// texture is the screen's, not the strip's, and so are the coordinates.
uniform vec2 uSize;
// (1, 0) across, (0, 1) down.
uniform vec2 uDir;
// The blur's sigma at the foot, in pixels.
uniform float uMost;
// The strip's top and foot on the screen, in pixels.
uniform float uTop;
uniform float uFoot;
uniform sampler2D uTexture;

out vec4 fragColor;

// What is under the strip at a point on the screen. OpenGL ES hands the
// texture over upside down.
vec4 under(vec2 q) {
  vec2 uv = clamp(q / uSize, 0.5 / uSize, 1.0 - 0.5 / uSize);
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTexture, uv);
}

const int TAPS = 12;

void main() {
  vec2 p = FlutterFragCoord().xy;
  float t = clamp((p.y - uTop) / (uFoot - uTop), 0.0, 1.0);
  // Eased in, so the start of it can't be told.
  float sigma = uMost * t * t;
  if (sigma < 0.25) {
    fragColor = under(p);
    return;
  }
  // Taps spread over three sigmas either side.
  float spacing = 3.0 * sigma / float(TAPS);
  vec4 sum = vec4(0.0);
  float total = 0.0;
  for (int i = -TAPS; i <= TAPS; i++) {
    float x = float(i) * spacing;
    float w = exp(-0.5 * x * x / (sigma * sigma));
    sum += under(p + uDir * x) * w;
    total += w;
  }
  fragColor = sum / total;
}
