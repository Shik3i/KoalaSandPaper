#[compute]
#version 450
// Velocity from position delta, damping, guards; clears own grid cell for the
// next substep; on the last substep writes the render state texture.
#include "common.glsli"
layout(local_size_x = WG) in;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.n) return;
	uint info = INFO[i];
	uint kind = kind_of(info);
	bool last = (pc.flags & FLAG_LAST) != 0u;
	ivec2 texel = ivec2(int(i % TEX_W), int(i / TEX_W));
	if (kind == KIND_NONE) {
		if (last) imageStore(RENDER_IMG, texel, vec4(0.0));
		return;
	}
	vec2 x = X[i];
	vec2 p = P_IN[i];
	vec2 d = p - x;
	float dl = length(d);
	if (dl > pc.max_step) {
		d *= pc.max_step / dl;
		atomicAdd(STATS[ST_CLAMP], 1u);
	}
	p = x + d;
	vec2 v = d / pc.h * pc.damp;
	if (any(isnan(p)) || any(isinf(p)) || any(isnan(v))) {
		atomicAdd(STATS[ST_NAN], 1u);
		p = x;
		v = vec2(0.0);
	}
	if (p.x < 0.0 || p.y < 0.0 || p.x > pc.world.x || p.y > pc.world.y) {
		atomicAdd(STATS[ST_OOB], 1u);
		p = clamp(p, vec2(pc.r), pc.world - pc.r);
	}
	X[i] = p;
	V[i] = v;
	CELL_COUNT[CELL_OF[i]] = 0u;
	if (last) {
		atomic_max_f(ST_MAX_SPEED, length(v));
		imageStore(RENDER_IMG, texel, vec4(p, float(COLOR[i] & 0xffffffu), float(kind)));
	}
}
