#[compute]
#version 450
// Predict positions (gravity, clamp to max_step) and insert into the cell grid.
#include "common.glsli"
layout(local_size_x = WG) in;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.n || kind_of(INFO[i]) == KIND_NONE) return;
	vec2 v = V[i] + pc.gravity * pc.h;
	vec2 d = v * pc.h;
	float dl = length(d);
	if (dl > pc.max_step) {
		d *= pc.max_step / dl;
		atomicAdd(STATS[ST_CLAMP], 1u);
	}
	vec2 p = X[i] + d;
	P_IN[i] = p;
	uvec2 cc = cell_coord(p);
	uint c = cc.y * pc.grid_w + cc.x;
	CELL_OF[i] = c;
	uint slot = atomicAdd(CELL_COUNT[c], 1u);
	if (slot < CELL_CAP) {
		CELL_ITEMS[c * CELL_CAP + slot] = i;
	} else {
		atomicAdd(STATS[ST_OVERFLOW], 1u);
	}
}
