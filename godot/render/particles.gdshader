shader_type canvas_item;
render_mode skip_vertex_transform, unshaded;

// Particle state from the solver: xy = position (m), z = 0xRRGGBB, w = kind.
uniform sampler2D state_tex : filter_nearest;
uniform float px_per_m = 100.0;
uniform float world_h = 7.2;
uniform float ref_d_px = 4.0; // 2R in px
// w packs kind (3 bit) | radius code (8 bit) | heat (8 bit); r = R (1 + poly (code/127.5 - 1)).
uniform float poly = 0.1;
uniform vec3 light_dir = vec3(-0.45, 0.6, 0.66);

varying vec3 tint;
varying vec2 local;
varying float radius_px;
varying float heat;

void vertex() {
	vec4 s = texelFetch(state_tex, ivec2(INSTANCE_ID % 1024, INSTANCE_ID / 1024), 0);
	uint rgb = uint(s.z);
	tint = vec3(float((rgb >> 16u) & 255u), float((rgb >> 8u) & 255u), float(rgb & 255u)) / 255.0;
	local = UV * 2.0 - 1.0;
	vec2 c = vec2(s.x, world_h - s.y) * px_per_m;
	// +0.5 px padding so the anti-aliased edge is not clipped.
	uint w = uint(s.w);
	uint kind = w & 7u;
	radius_px = 0.5 * ref_d_px * (1.0 + poly * (float((w >> 3u) & 255u) / 127.5 - 1.0));
	heat = float(w >> 11u) / 255.0;
	// Grains of intact rigid pieces are drawn slightly larger: the piece reads as a solid block.
	if (kind == 4u) radius_px *= 1.18;
	VERTEX = kind == 0u ? vec2(-1e6) : c + local * (radius_px + 0.5);
}

void fragment() {
	float rad = (radius_px + 0.5) / max(radius_px, 0.5);
	vec2 q = local * rad;
	float d2 = dot(q, q);
	// ~1 px wide coverage ramp at the rim.
	float alpha = clamp((1.0 - sqrt(d2)) * radius_px + 0.5, 0.0, 1.0);
	vec3 n = vec3(q.x, -q.y, sqrt(max(1.0 - d2, 0.0)));
	vec3 l = normalize(light_dir);
	float diff = max(dot(n, l), 0.0);
	float spec = pow(max(dot(reflect(-l, n), vec3(0.0, 0.0, 1.0)), 0.0), 24.0);
	vec3 col = tint * (0.45 + 0.6 * diff) + vec3(0.25) * spec;
	// Incandescence: dark red → orange → yellow-white, overdriven for glow.
	vec3 hot = mix(vec3(0.9, 0.15, 0.02), vec3(1.0, 0.75, 0.3), smoothstep(0.4, 1.0, heat));
	col = mix(col, hot * (1.0 + 2.5 * heat), smoothstep(0.05, 0.5, heat));
	COLOR = vec4(col, alpha);
}
