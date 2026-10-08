#[compute]
#version 450
// Pre-stabilisation (Macklin et al. 2014, §4.4): resolve contacts that already
// overlap at the substep start, using start positions X and machine poses at
// the substep start. The result shifts positions only (STAB), never velocity,
// so pinches, jams and spawn overlaps cannot launch grains.
#include "common.glsli"
#include "colliders.glsli"
layout(local_size_x = WG) in;

#define FLAG_NOSTAB 2u

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.n || pc.laser_b.x < -1e30) return;
	uint info = INFO[i];
	uint kind = kind_of(info);
	if (kind == KIND_NONE || kind == KIND_SPARK || kind == KIND_RIGID || (pc.flags & FLAG_NOSTAB) != 0u) {
		STAB[i] = vec2(0.0);
		return;
	}
	vec2 xi = X[i];
	float ri = RAD[i];
	vec4 mi = MAT[2u * mat_of(info)];
	float wi = inv_mass(info, ri);
	Acc a = Acc(vec2(0.0), 0.0, 0.0);

	uint c = cell_of(i);
	int cx = int(c % pc.grid_w);
	int cy = int(c / pc.grid_w);
	for (int oy = -1; oy <= 1; oy++) {
		int y = cy + oy;
		if (y < 0 || y >= int(pc.grid_h)) continue;
		for (int ox = -1; ox <= 1; ox++) {
			int x = cx + ox;
			if (x < 0 || x >= int(pc.grid_w)) continue;
			uint cell = uint(y) * pc.grid_w + uint(x);
			uint m = count_at(cell);
			for (uint s = 0u; s < m; s++) {
				uint j = CELL_ITEMS[cell * CELL_CAP + s];
				if (j == i) continue;
				vec2 dv = xi - X[j];
				float rj = RAD[j];
				float d0 = ri + rj;
				float d2 = dot(dv, dv);
				if (d2 >= d0 * d0) continue;
				uint infoj = INFO[j];
				if (kind_of(infoj) == KIND_SPARK) continue;
				if (same_unit(i, j, kind, kind_of(infoj))) continue;
				float dist = sqrt(d2);
				vec2 n = dist > 1e-9 * pc.r ? dv / dist : vec2(0.0, i < j ? 1.0 : -1.0);
				float wib = wi * exp(pc.stack_k * dv.y / pc.r);
				acc_add(a, n * ((d0 - dist) * wib / (wib + particle_w(j, infoj, rj))));
			}
		}
	}
	Surf su = Surf(xi + pc.omega * acc_total(a), vec2(0.0), false, vec4(0.0));
	collider_contacts(pc.t_sub - pc.h, true, ri, mi, su);
	world_walls(ri, vec4(0.0), su);
	vec2 s = su.p - xi;
	float sl = length(s);
	STAB[i] = sl > pc.max_step ? s * (pc.max_step / sl) : s;
}
