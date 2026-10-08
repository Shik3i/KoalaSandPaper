shader_type canvas_item;
// Factory hall backdrop: vertical gradient, faint blueprint grid (every 0.5 m,
// stronger every 2 m), soft vignette and fine noise against banding.

uniform float px_per_m = 156.0;
uniform vec2 size_px = vec2(1920.0, 1080.0);
uniform vec3 top_col : source_color = vec3(0.055, 0.094, 0.125);
uniform vec3 bottom_col : source_color = vec3(0.078, 0.133, 0.169);

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	vec2 px = UV * size_px;
	vec3 col = mix(top_col, bottom_col, UV.y);
	vec2 m = px / px_per_m;
	vec2 g = abs(fract(m * 2.0 + 0.5) - 0.5) / fwidth(m * 2.0);
	float fine = 1.0 - clamp(min(g.x, g.y), 0.0, 1.0);
	vec2 g2 = abs(fract(m * 0.5 + 0.5) - 0.5) / fwidth(m * 0.5);
	float coarse = 1.0 - clamp(min(g2.x, g2.y), 0.0, 1.0);
	col += vec3(0.35, 0.55, 0.65) * (0.018 * fine + 0.035 * coarse);
	vec2 v = UV - 0.5;
	col *= 1.0 - 0.55 * dot(v, v);
	col += (hash(px) - 0.5) / 255.0;
	COLOR = vec4(col, 1.0);
}
