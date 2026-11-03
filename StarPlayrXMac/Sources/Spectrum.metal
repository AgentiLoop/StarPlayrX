//
//  Spectrum.metal
//  StarPlayrXMac
//
//  Created by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The lava-lamp equalizer: blob, glows, bars and bubbles, all drawn by one fragment shader.
//  SpectrumRenderer (Visualizer.swift) feeds it Globals and one Bar per band each frame.

#include <metal_stdlib>
using namespace metal;

// Number of bars; set from Visualizer.bandCount when the pipeline is built.
constant int BANDS [[function_constant(0)]];

struct Bar { float4 base, top, glow, shade, misc, curve; };
struct Globals {
    float4 view;       // bars width, bars height (pt), pixels per point, overhang (pt)
    float4 state;      // pulse, light panel, bubble strength, seconds
    float4 bubble;     // bubble colour, alpha
    float4 blob;       // blob colour, opacity
    float4 blobShape;  // x offset (pt), x scale, y scale, y offset (pt, down)
    float4 glowStyle;  // glow opacity, glow radius (pt), tween 0...1 from the previous step
};

vertex float4 spectrumVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);   // one triangle covering the view
    return float4(p * 2 - 1, 0, 1);
}

static float roundedRect(float2 p, float2 centre, float2 hs, float r) {
    float2 q = abs(p - centre) - (hs - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float ellipse(float2 p, float2 r) {
    float k0 = length(p / r), k1 = length(p / (r * r));
    return k1 > 0 ? k0 * (k0 - 1) / k1 : -min(r.x, r.y);
}

static float cover(float sd, float px) { return saturate(0.5 - sd / px); }

static float4 over(float4 dst, float3 rgb, float a) { return float4(rgb * a, a) + dst * (1 - a); }

// Fixed per bar and slot (so nothing flickers): size, spacing jitter, sway and wobble rate.
static float hash(float seed, float k, float salt) {
    return fract(abs(sin(seed * 12.9898 + k * 78.233 + salt) * 43758.5453));
}

// Lava-lamp blobs rising through a bar: 3 or 4 per bar, unevenly spaced, each with its own size.
// They slowly stretch and squash as they climb, sway, breathe, and fade in at the bottom and out at the top.
static float4 bubbles(float4 dst, float2 lp, float2 size, int i, Bar b, constant Globals &g, float px) {
    float seed = i, strength = g.state.z, now = g.state.w;
    int count = 3 + i % 2;
    for (int k = 0; k < count; k++) {
        float fk = k;
        float slot = (fk + 0.6 * hash(seed, fk, 1)) / count;
        float p = fract(b.misc.y + slot + seed * 0.137);
        float period = 3 + 3 * hash(seed, fk, 5);
        float breath = 1 + 0.4 * sin(2 * M_PI_F * (now / period + hash(seed, fk, 6)));
        float d = min(size.x * (0.2 + 0.65 * hash(seed, fk, 0)), size.y * 0.35) * breath;
        float wobble = 0.06 * sin(p * 2 * M_PI_F * (1.5 + hash(seed, fk, 2)) + fk);
        float2 r = float2(d * (1 - wobble), d * (1 + wobble)) / 2;
        float2 c = float2(size.x / 2 + size.x * 0.12 * sin(p * (4 + 3 * hash(seed, fk, 3)) + seed * 2 + fk),
                          size.y + r.y - (size.y + 2 * r.y) * p);   // in from the bottom, out the top
        float fade = min(1.0, sin(p * M_PI_F) * 2) * strength;
        float look = hash(seed, fk, 4);
        if (look < 0.33) {
            // The bar's own colour, solid, 1 pt down and right: a shadow you only just notice.
            dst = over(dst, b.shade.rgb, fade * cover(ellipse(lp - c - 1, r), px));
        } else if (look > 0.67) {
            float2 hr = r * 1.8;
            float glow = 1 - saturate(length(lp - c) / max(hr.x, hr.y));
            dst = over(dst, float3(1), 0.22 * fade * glow * cover(ellipse(lp - c, hr), px));
        }
        // Soft: fades from a gentle centre to nothing at the edge, with no hard rim or highlight.
        float t = length(lp - (c - 0.2 * r)) / (1.2 * max(r.x, r.y));
        float a = t < 0.5 ? mix(0.3, 0.14, t / 0.5) : mix(0.14, 0.0, saturate((t - 0.5) / 0.5));
        dst = over(dst, g.bubble.rgb, a * g.bubble.a * fade * cover(ellipse(lp - c, r), px));
    }
    return dst;
}

fragment float4 spectrumFragment(float4 pos [[position]], constant Globals &g [[buffer(0)]],
                                 constant Bar *bars [[buffer(1)]]) {
    float W = g.view.x, H = g.view.y, px = 1 / g.view.z;
    float2 p = pos.xy * px - g.view.w;   // points, from the bars' top-left
    float4 out = 0;

    // Blurred blob behind the bars.
    float2 br = max(float2(W / 2 * g.blobShape.y, H / 2 * g.blobShape.z), 0.5);
    float bsd = ellipse(p - float2(W / 2 + g.blobShape.x, H / 2 + g.blobShape.w), br);
    out = over(out, g.blob.rgb, g.blob.a * (1 - smoothstep(-14.0, 14.0, bsd)));

    float bw = (W - 2 * (BANDS - 1)) / BANDS;
    float sigma = max(g.glowStyle.y * 0.5, 0.5);
    for (int i = 0; i < BANDS; i++) {
        Bar b = bars[i];
        // Tween from the previous 30 Hz step to this one; rise wraps at 1, so go forward round it.
        float t = g.glowStyle.z;
        // Height: a Catmull-Rom curve through the last four steps, drawn between the middle two.
        // Speed changes smoothly from one step to the next instead of jumping at every step,
        // so the bars glide up and down rather than moving in straight segments.
        float4 k = b.curve;
        b.misc.x = saturate(0.5 * (2 * k.y + (k.z - k.x) * t + (2 * k.x - 5 * k.y + 4 * k.z - k.w) * t * t
                                   + (3 * k.y - k.x - 3 * k.z + k.w) * t * t * t));
        float r1 = b.misc.y < b.misc.w ? b.misc.y + 1 : b.misc.y;
        b.misc.y = fract(mix(b.misc.w, r1, t));
        float hb = max(2.0, b.misc.x * H);
        float2 hs = float2(bw, hb) / 2;
        float2 centre = float2(i * (bw + 2) + hs.x, H - hs.y);
        float sd = roundedRect(p, centre, hs, 1.5);
        if (sd > 3 * sigma + 1) continue;
        float d = max(sd, 0.0);
        // out = over(out, b.glow.rgb, g.glowStyle.x * exp(-d * d / (2 * sigma * sigma)));
        float c = cover(sd, px);
        if (c <= 0) continue;
        float2 lp = p - (centre - hs);
        float4 bar = float4(mix(b.base.rgb, b.top.rgb, saturate(1 - lp.y / hb)), 1);
        // On a light panel a thin dark edge keeps pale bars from melting into it.
        if (g.state.y > 0.5 && sd > -0.5) bar = over(bar, float3(0), 0.25);
        if (g.state.z > 0 && hb > 8) bar = bubbles(bar, lp, float2(bw, hb), i, b, g, px);
        out = bar * c + out * (1 - c);
    }
    return out;
}
