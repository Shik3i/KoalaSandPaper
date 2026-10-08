#[compute]
#version 450
// Rigid pieces: predict each live body's pose for this substep.
#include "common.glsli"
layout(local_size_x = WG) in;

void main() {
	uint b = gl_GlobalInvocationID.x;
	if (b >= pc.n_pieces * BODIES_PER_PIECE || pc.laser_b.x < -1e30) return;
	vec4 c = RB[4u * b];
	if (c.w < 0.5) return;
	vec4 v = RB[4u * b + 1u];
	v.xy = (v.xy + pc.gravity * pc.h) * pc.damp;
	RB[4u * b + 1u] = v;
	RB[4u * b + 2u] = vec4(c.xy + v.xy * pc.h, c.z + v.z * pc.h, RB[4u * b + 2u].w);
}
