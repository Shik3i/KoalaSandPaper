#[compute]
#version 450
// Spawns rigid piece pc.aux: its grains (staged in STAGE) go to the slots listed in
// PLIST[piece * MAX_PIECE_GRAINS + t], which need not be contiguous (free slots
// are scattered once sand burns at random). The grains start without contact
// history (RANK = none).
#include "common.glsli"
layout(local_size_x = 64) in;

void main() {
	uint t = gl_GlobalInvocationID.x;
	if (t >= pc.n || pc.guard < -1e30) return;
	uint piece = pc.aux;
	uint i = PLIST[piece * MAX_PIECE_GRAINS + t];
	vec4 a = STAGE[2u * t];
	vec4 b = STAGE[2u * t + 1u];
	XV[i] = a;
	REST[i] = b.xy;
	INFO[i] = floatBitsToUint(b.z);
	COLOR[i] = floatBitsToUint(b.w);
	BODY_OF[i] = piece * NSUB;
	VN[i] = vec2(0.0);  // chip counter
	W[i] = 0.0;
	RANK[i] = CELL_NONE;
}
