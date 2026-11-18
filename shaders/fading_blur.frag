#version 460 core

// A blur up and down only, none at the top of the strip, growing row by
// row to its most at the foot: the ground under the tab bar. One pass, for
// a small blur, where blurring one way can't be told from blurring both;
// a second pass across never showed (on Impeller it read the screen as it
// was, not this pass's output).

#include <flutter/runtime_effect.glsl>

precision highp float;

// Set by the engine: the size of what is under the strip, and it. The
// texture is the screen's, not the strip's, and so are the coordinates.
uniform vec2 uSize;
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
    float y = float(i) * spacing;
    float w = exp(-0.5 * y * y / (sigma * sigma));
    sum += under(p + vec2(0.0, y)) * w;
    total += w;
  }
  fragColor = sum / total;
}
