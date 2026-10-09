#[compute]
#version 450
// Apply the pre-stabilisation shift (position only), predict this substep's
// displacement (gravity, or the rigid body's predicted pose), clamp to
// max_step, insert into the neighbour grid and publish (X, D) packed.
#include "common.glsli"
layout(local_size_x = WG) in;

void main() {
	uint i = gl_GlobalInvocationID.x;
	// Reference the last push-constant member so every kernel declares the same block size.
	if (i >= pc.n || pc.laser_b.x < -1e30) return;
	uint info = INFO[i];
	uint kind = kind_of(info);
	if (kind == KIND_NONE) {
		CELL_OF[par() * pc.cap + i] = CELL_NONE;
		return;
	}
	vec2 x = X[i];
	vec2 d;
	if (kind == KIND_RIGID) {
		// Grain rides its body's predicted pose (rigid_solve predicts the next substep).
		uint b = BODY_OF[i];
		vec4 ps = RB[4u * b + 2u];
		d = ps.xy + rot(ps.z) * (REST[i] - RB[4u * b + 3u].xy) - x;
	} else {
		vec2 s = STAB[i];
		x += s;
		X[i] = x;
		STAB[i] = vec2(0.0);
		d = (V[i] + pc.gravity * pc.h) * pc.h;
	}
	float dl = length(d);
	if (dl > pc.max_step) {
		d *= pc.max_step / dl;
		atomicAdd(STATS[ST_CLAMP], 1u);
		STATS[ST_CLAMP_POS] = floatBitsToUint(x.x);
		STATS[ST_CLAMP_POS + 1] = floatBitsToUint(x.y);
	}
	D_IN[i] = d;
	D_OUT[i] = d;  // default if the contact pass never sees this grain (cell overflow)
	XD[i] = vec4(x, d);
	if (kind == KIND_RIGID) FRIC[i] = vec4(0.0);
	if (kind == KIND_SPARK) {
		CELL_OF[par() * pc.cap + i] = CELL_NONE;
		return;
	}
	vec2 p = x + d;
	uvec2 cc = cell_coord(p);
	uint c = cc.y * pc.grid_w + cc.x;
	CELL_OF[par() * pc.cap + i] = c;
	uint slot = atomicAdd(CELL_COUNT[par() * cells_total() + c], 1u);
	if (slot < CELL_CAP) {
		CELL_ITEMS[c * CELL_CAP + slot] = i;
	} else {
		atomicAdd(STATS[ST_OVERFLOW], 1u);
		STATS[ST_OVF_POS] = floatBitsToUint(p.x);
		STATS[ST_OVF_POS + 1] = floatBitsToUint(p.y);
	}
}
