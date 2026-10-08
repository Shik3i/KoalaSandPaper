shader_type canvas_item;
// Furnace fire: rising turbulent flames from the grate, HDR so the bloom picks
// it up. UV.y = 0 at the top of the rect, 1 at the grate.

uniform float intensity = 1.0;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
	float a = 0.5, s = 0.0;
	for (int k = 0; k < 5; k++) { s += a * noise(p); p *= 2.03; a *= 0.5; }
	return s;
}

void fragment() {
	float t = TIME;
	vec2 uv = UV;
	float h = 1.0 - uv.y;                       // height above the grate, 0..1
	vec2 p = vec2(uv.x * 6.0, h * 3.0 - t * 1.6);
	float n = fbm(p + vec2(fbm(p + t * 0.3) * 1.5, 0.0));
	float flame = smoothstep(0.0, 1.0, n * 1.6 - h * 1.35);
	vec3 col = mix(vec3(0.7, 0.08, 0.01), vec3(1.0, 0.55, 0.12), flame);
	col = mix(col, vec3(1.0, 0.9, 0.6), smoothstep(0.75, 1.0, flame));
	float base_glow = 0.35 * (1.0 - smoothstep(0.0, 0.6, h));
	float a = clamp(flame + base_glow, 0.0, 1.0) * intensity;
	COLOR = vec4(col * (1.0 + 2.2 * flame) * intensity, a * 0.92);
}
