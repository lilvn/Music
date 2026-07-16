#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// An audio-reactive "lava lamp" background. The view's own content — the blurred album art — is the
// colour source; this shader paints churning metaball blobs from it: bright and swollen inside the
// blobs, dim between them, all flowing and pulsing with the music. It runs on the GPU (one pass per
// frame while Now Playing is open); the CPU only pushes `time` and `level`, so it stays cheap.
//
// Args: `size` = view size in points, `time` = seconds since the view appeared (small, keeps float
// precision), `level` = smoothed audio level 0…1.
[[ stitchable ]] half4 lavaLamp(float2 pos, SwiftUI::Layer layer, float2 size, float time, float level) {
    float2 uv = pos / size;
    float aspect = size.x / max(size.y, 1.0);

    // Metaball field: six blobs each drifting on its own slow loop. The music speeds their drift and
    // swells their radius, so a loud section churns and blooms while a quiet one settles.
    float field = 0.0;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float speed = 0.10 + 0.12 * level;                      // drifts faster with the music
        float t = time * speed + fi * 2.399963;                 // spread the blobs' phases apart
        float2 c = float2(0.5 + 0.34 * sin(t * (0.90 + 0.06 * fi) + fi * 1.3),
                          0.5 + 0.34 * cos(t * (0.78 + 0.10 * fi) - fi * 0.7));
        float r = (0.15 + 0.04 * sin(t * 1.7 + fi)) * (1.0 + 0.7 * level);   // and swells on the beat
        float2 d = uv - c;
        d.x *= aspect;                                          // keep blobs round on a tall view
        field += (r * r) / (dot(d, d) + 0.0006);
    }

    // Soft lava surface from the field.
    float m = smoothstep(0.70, 1.55, field);

    // Colour from the blurred art, sampled with a slow churn offset so the lava isn't a flat wash.
    float2 churn = float2(sin(uv.y * 5.0 + time * 0.22), cos(uv.x * 4.0 - time * 0.19));
    float2 samplePos = pos + churn * min(size.x, size.y) * 0.05;
    half4 art = layer.sample(samplePos);

    half4 between = art * half(0.5);                            // dim colour between blobs
    half4 inside = art * half(1.15 + 0.5 * level);              // bright inside, pulses with the beat
    half4 lava = mix(between, inside, half(m));
    lava.a = art.a;                                             // preserve the source's coverage
    return lava;
}
