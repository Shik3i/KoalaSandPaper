#[compute]
#version 450
// Predict positions (gravity, clamp to max_step) and insert into the cell grid.
#include "common.glsli"
layout(local_size_x = WG) in;

void main() {
	uint i = gl_GlobalInvocationID.x;
	// Reference the last push-constant member so every kernel declares the same block size.
	if (i >= pc.n || pc.laser_b.x < -1e30) return;
	uint kind = kind_of(INFO[i]);
	if (kind == KIND_NONE) {
		CELL_OF[par() * pc.n + i] = CELL_NONE;
		return;
	}
	vec2 v = V[i] + pc.gravity * pc.h;
	vec2 d = v * pc.h;
	float dl = length(d);
	if (dl > pc.max_step) {
		d *= pc.max_step / dl;
		atomicAdd(STATS[ST_CLAMP], 1u);
		STATS[ST_CLAMP_POS] = floatBitsToUint(X[i].x);
		STATS[ST_CLAMP_POS + 1] = floatBitsToUint(X[i].y);
	}
	D_IN[i] = d;
	vec2 p = X[i] + d;
	uvec2 cc = cell_coord(p);
	uint c = cc.y * pc.grid_w + cc.x;
	if (kind == KIND_SPARK) {
		CELL_OF[par() * pc.n + i] = CELL_NONE;
		return;
	}
	CELL_OF[par() * pc.n + i] = c;
	uint slot = atomicAdd(CELL_COUNT[par() * cells_total() + c], 1u);
	if (slot < CELL_CAP) {
		CELL_ITEMS[c * CELL_CAP + slot] = i;
	} else {
		atomicAdd(STATS[ST_OVERFLOW], 1u);
		STATS[ST_OVF_POS] = floatBitsToUint(p.x);
		STATS[ST_OVF_POS + 1] = floatBitsToUint(p.y);
	}
}
