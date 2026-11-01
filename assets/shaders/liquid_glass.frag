// Flutter GLSL adaptation of Kyant's Backdrop rounded rectangle lens.
// Copyright 2025 Kyant. Licensed under the Apache License, Version 2.0.
// See assets/licenses/AndroidLiquidGlass-LICENSE.txt.
// Modified for Flutter's image filter coordinates, bounded RGB dispersion,
// premultiplied alpha, and a three-sample path instead of seven samples.
#version 460 core
#include <flutter/runtime_effect.glsl>

// The engine supplies the input texture's size and first sampler.
uniform vec2 u_size;
uniform vec4 u_lens;
uniform vec2 u_optics;
uniform sampler2D u_texture;
out vec4 fragColor;

float roundedRectDistance(vec2 p, vec2 halfSize, float radius) {
  vec2 corner = abs(p) - halfSize + radius;
  return length(max(corner, 0.0)) - radius
      + min(max(corner.x, corner.y), 0.0);
}

vec2 safeNormal(vec2 p) {
  return p / max(length(p), 0.0001);
}

vec2 roundedRectNormal(vec2 p, vec2 halfSize, float radius) {
  vec2 corner = abs(p) - halfSize + radius;
  if (corner.x >= 0.0 || corner.y >= 0.0) {
    return sign(p) * safeNormal(max(corner, 0.0));
  }
  float x = step(corner.y, corner.x);
  return sign(p) * vec2(x, 1.0 - x);
}

vec4 sampleContent(vec2 p) {
  vec2 uv = clamp(p / u_size, vec2(0.0), vec2(1.0));
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(u_texture, uv);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 halfSize = u_size * 0.5;
  vec2 centered = p - halfSize;
  float shortest = min(u_size.x, u_size.y);
  float radius = min(u_lens.x * shortest, shortest * 0.5);
  float rimHeight = max(u_lens.y * shortest, 0.0001);
  float amount = u_lens.z * shortest;
  float distance = min(roundedRectDistance(centered, halfSize, radius), 0.0);
  float t = clamp(1.0 + distance / rimHeight, 0.0, 1.0);
  float displacement = (1.0 - sqrt(max(1.0 - t * t, 0.0))) * amount;
  float gradientRadius = min(radius * 1.5, shortest * 0.5);
  vec2 normal = safeNormal(
      roundedRectNormal(centered, halfSize, gradientRadius)
      + u_lens.w * safeNormal(centered));
  vec2 refracted = p - displacement * normal;
  vec4 color = sampleContent(refracted);
  if (u_optics.x > 0.0 && displacement > 0.0) {
    float dispersion = u_optics.x * centered.x * centered.y
        / max(halfSize.x * halfSize.y, 0.0001);
    vec2 separated = displacement * normal * dispersion;
    color.r = sampleContent(refracted + separated).r;
    color.b = sampleContent(refracted - separated).b;
  }
  float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
  color.rgb = clamp(mix(vec3(luminance), color.rgb, u_optics.y),
      vec3(0.0), vec3(color.a));
  fragColor = color;
}
