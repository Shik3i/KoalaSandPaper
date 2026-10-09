#[compute]
#version 450
// Position update (X += D, or the solved rigid pose), velocity from the position
// solve (XV.zw; the velocity pass makes it final), sinks and heat zones, guards;
// on the last substep writes the render state texture.
#include "common.glsli"
#include "colliders.glsli"
layout(local_size_x = WG) in;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.n || pc.laser_b.x < -1e30) return;
	uint info = INFO[i];
	uint kind = kind_of(info);
	bool last = (pc.flags & FLAG_LAST) != 0u;
	ivec2 texel = ivec2(int(i % TEX_W), int(i / TEX_W));
	if (kind == KIND_NONE) {
		if (last) imageStore(RENDER_IMG, texel, vec4(0.0));
		return;
	}
	vec2 x = X[i];
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
	// Zones: sinks remove; heat zones heat grains until they burn. Outside, grains cool.
	uint heat = heat_of(info);
	bool heating = false;
	uint pcell = pgrid_cell(p);
	uint pcnt = PGRID[pcell];
	for (uint gi = 1u; gi <= pcnt; gi++) {
		Prim pr = PRIMS[PGRID[pcell + gi]];
		if ((pr.head.w & 10u) == 0u) continue;
		vec2 bpos, bvel;
		float bang, bom;
		body_pose(pr.head.y, pc.t_sub, bpos, bang, bvel, bom);
		if (prim_sdf(pr, rot(-bang) * (p - bpos)) >= 0.0) continue;
		if ((pr.head.w & 8u) != 0u && heat < 250u) {
			heating = true;
			continue;
		}
		INFO[i] = 0u;
		atomicAdd(STATS[8u + min(pr.head.w >> 8u, 3u)], 1u);
		atomicAdd(STATS[ST_SUNK], 1u);
		if (last) imageStore(RENDER_IMG, texel, vec4(0.0));
		return;
	}
	uint sc = substep_counter();
	if (heating) {
		if (sc % 8u == 0u) heat += 1u;
	} else if (heat > 0u && sc % 24u == 0u) {
		heat -= 1u;
	}
	info = with_heat(info, heat);
	INFO[i] = info;
	X[i] = p;
	VOLD[i] = V[i];
	V[i] = v;  // default if the velocity pass never sees this grain
	XV[i] = vec4(p, v);
	if (last) {
		// w packs kind (3 bit) | radius code (8 bit) | heat (8 bit): exact in float.
		uint w = min(kind, 7u) | (((info >> 16u) & 0xffu) << 3u) | (heat << 11u);
		imageStore(RENDER_IMG, texel, vec4(p, float(COLOR[i] & 0xffffffu), float(w)));
	}
}
