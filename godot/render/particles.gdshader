shader_type canvas_item;
render_mode skip_vertex_transform, unshaded;

// Particle state from the solver: xy = position (m), z = 0xRRGGBB, w = kind.
uniform sampler2D state_tex : filter_nearest;
uniform float px_per_m = 100.0;
uniform float world_h = 7.2;
uniform float radius_px = 2.0;
uniform vec3 light_dir = vec3(-0.45, 0.6, 0.66);

varying vec3 tint;
varying vec2 local;

void vertex() {
	vec4 s = texelFetch(state_tex, ivec2(INSTANCE_ID % 1024, INSTANCE_ID / 1024), 0);
	uint rgb = uint(s.z);
	tint = vec3(float((rgb >> 16u) & 255u), float((rgb >> 8u) & 255u), float(rgb & 255u)) / 255.0;
	local = UV * 2.0 - 1.0;
	vec2 c = vec2(s.x, world_h - s.y) * px_per_m;
	// +0.5 px padding so the anti-aliased edge is not clipped.
	VERTEX = s.w < 0.5 ? vec2(-1e6) : c + local * (radius_px + 0.5);
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
	COLOR = vec4(col, alpha);
}
