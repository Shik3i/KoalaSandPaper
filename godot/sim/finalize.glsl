#[compute]
#version 450
// Position update (X += STAB + D), velocity from the position solve into VN
// (the velocity pass makes it final), sinks, guards; on the last substep writes
// the render state texture.
#include "common.glsli"
#include "colliders.glsli"
layout(local_size_x = WG) in;

void main() {
	uint i = gl_GlobalInvocationID.x;
	// Reference the last push-constant member so every kernel declares the same block size.
	if (i >= pc.n || pc.laser_b.x < -1e30) return;
	uint info = INFO[i];
	uint kind = kind_of(info);
	bool last = (pc.flags & FLAG_LAST) != 0u;
	ivec2 texel = ivec2(int(i % TEX_W), int(i / TEX_W));
	if (kind == KIND_NONE) {
		if (last) imageStore(RENDER_IMG, texel, vec4(0.0));
		return;
	}
	vec2 x = X[i] + STAB[i];
	vec2 d = D_IN[i];
	if (kind == KIND_RIGID) {
		// Final pose solved by rigid_solve.glsl.
		uint b = BODY_OF[i];
		vec4 c = RB[4u * b];
		d = c.xy + rot(c.z) * (REST[i] - RB[4u * b + 3u].xy) - x;
	}
	float dl = length(d);
	if (dl > pc.max_step) {
		d *= pc.max_step / dl;
		dl = pc.max_step;
		atomicAdd(STATS[ST_CLAMP], 1u);
		STATS[ST_CLAMP_POS] = floatBitsToUint(x.x);
		STATS[ST_CLAMP_POS + 1] = floatBitsToUint(x.y);
	}
	vec2 v = d / pc.h * pc.damp;
	// Sleep: sub-threshold motion keeps velocity state but not position (kills creep).
	vec2 p = dl < pc.sleep ? x : x + d;
	if (any(isnan(p)) || any(isinf(p)) || any(isnan(v)) || any(isinf(v))) {
		atomicAdd(STATS[ST_NAN], 1u);
		p = x;
		v = vec2(0.0);
	}
	if (p.x < 0.0 || p.y < 0.0 || p.x > pc.world.x || p.y > pc.world.y) {
		atomicAdd(STATS[ST_OOB], 1u);
		p = clamp(p, vec2(pc.r), pc.world - pc.r);
	}
	for (uint k = 0u; k < pc.n_prims; k++) {
		Prim pr = PRIMS[k];
		if ((pr.head.w & 2u) == 0u) continue;  // sinks only
		vec2 bpos, bvel;
		float bang, bom;
		body_pose(pr.head.y, pc.t_sub, bpos, bang, bvel, bom);
		if (prim_sdf(pr, rot(-bang) * (p - bpos)) < 0.0) {
			INFO[i] = 0u;
			atomicAdd(STATS[8u + min(pr.head.w >> 8u, 3u)], 1u);
			atomicAdd(STATS[ST_SUNK], 1u);
			if (last) imageStore(RENDER_IMG, texel, vec4(0.0));
			return;
		}
	}
	X[i] = p;
	VOLD[i] = V[i];
	VN[i] = v;
	if (last) {
		float w = float(kind) + clamp(RAD[i] / (2.0 * pc.r), 0.0, 0.999);
		imageStore(RENDER_IMG, texel, vec4(p, float(COLOR[i] & 0xffffffu), w));
	}
}
