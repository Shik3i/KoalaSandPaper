shader_type canvas_item;
render_mode skip_vertex_transform, unshaded;

// Particle state from the solver: xy = position (m), z = 0xRRGGBB,
// w packs kind (3 bit) | radius code (8 bit) | heat (8 bit) | contacts (3 bit);
// r = R (1 + poly (code/127.5 - 1)).
uniform sampler2D state_tex : filter_nearest;
uniform float px_per_m = 100.0;
uniform float world_h = 7.2;
uniform float ref_d_px = 4.0; // 2R in px
uniform float poly = 0.1;
// Shadow pass: soft dark disc offset down-right, drawn under the grains.
uniform bool shadow = false;
uniform vec3 light_dir = vec3(-0.5, 0.65, 0.58);

varying vec3 tint;
varying vec2 local;
varying float radius_px;
varying float heat;
varying float rigid;
varying float occl;

void vertex() {
	vec4 s = texelFetch(state_tex, ivec2(INSTANCE_ID % 1024, INSTANCE_ID / 1024), 0);
	uint rgb = uint(s.z);
	tint = vec3(float((rgb >> 16u) & 255u), float((rgb >> 8u) & 255u), float(rgb & 255u)) / 255.0;
	local = UV * 2.0 - 1.0;
	vec2 c = vec2(s.x, world_h - s.y) * px_per_m;
	uint w = uint(s.w);
	uint kind = w & 7u;
	radius_px = 0.5 * ref_d_px * (1.0 + poly * (float((w >> 3u) & 255u) / 127.5 - 1.0));
	heat = float((w >> 11u) & 255u) / 255.0;
	// Ambient occlusion from the contact count: buried grains (5-6 contacts) darker,
	// surface grains (2-3) light, so heaps read as volumes.
	occl = mix(1.0, 0.62, smoothstep(2.5, 5.5, float((w >> 19u) & 7u)));
	rigid = kind == 4u ? 1.0 : 0.0;
	// Grains of rigid pieces/chunks are drawn larger and flat (fragment()): they
	// merge into one solid body instead of a lattice of shaded balls (moiré).
	if (kind == 4u) radius_px *= 1.5;
	if (shadow) {
		c += vec2(0.45, 0.6) * radius_px;
		radius_px *= 1.35;
	}
	// +0.5 px padding so the anti-aliased edge is not clipped.
	VERTEX = kind == 0u ? vec2(-1e6) : c + local * (radius_px + 0.5);
}

void fragment() {
	float rad = (radius_px + 0.5) / max(radius_px, 0.5);
	vec2 q = local * rad;
	float d2 = dot(q, q);
	if (shadow) {
		COLOR = vec4(0.0, 0.0, 0.0, 0.42 * (1.0 - smoothstep(0.2, 1.0, sqrt(d2))) * (1.0 - heat));
	} else {
		// ~1 px wide coverage ramp at the rim.
		float alpha = clamp((1.0 - sqrt(d2)) * radius_px + 0.5, 0.0, 1.0);
		vec3 n = vec3(q.x, -q.y, sqrt(max(1.0 - d2, 0.0)));
		vec3 l = normalize(light_dir);
		float diff = max(dot(n, l), 0.0);
		float spec = pow(max(dot(reflect(-l, n), vec3(0.0, 0.0, 1.0)), 0.0), 20.0);
		// Cool rim light from below-right separates grains from the dark backdrop.
		float rim = pow(1.0 - n.z, 2.0) * max(dot(n.xy, normalize(vec2(0.7, -0.7))), 0.0);
		vec3 col = tint * (0.38 + 0.72 * diff) + vec3(0.28) * spec + vec3(0.25, 0.35, 0.45) * rim * 0.6;
		if (rigid > 0.5) col = tint * 0.92;
		else col *= occl;
		// Incandescence: dark red → orange → yellow-white, overdriven for bloom.
		vec3 hot = mix(vec3(1.0, 0.18, 0.03), vec3(1.0, 0.78, 0.35), smoothstep(0.45, 1.0, heat));
		col = mix(col, hot * (1.2 + 3.0 * heat), smoothstep(0.03, 0.4, heat));
		COLOR = vec4(col, alpha);
	}
}
