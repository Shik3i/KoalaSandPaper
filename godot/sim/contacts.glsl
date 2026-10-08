#[compute]
#version 450
// One Jacobi pass: particle contacts (Coulomb friction), bonds (XPBD distance,
// break on strain), machine colliders, world box. Reads D_IN, writes D_OUT
// with averaged corrections (Macklin 2014).
#include "common.glsli"
#include "colliders.glsli"
layout(local_size_x = WG) in;

bool segments_cross(vec2 p1, vec2 p2, vec2 q1, vec2 q2) {
	vec2 r = p2 - p1, s = q2 - q1;
	float den = r.x * s.y - r.y * s.x;
	if (abs(den) < 1e-14) return false;
	vec2 w = q1 - p1;
	float t = (w.x * s.y - w.y * s.x) / den;
	float u = (w.x * r.y - w.y * r.x) / den;
	return t >= 0.0 && t <= 1.0 && u >= 0.0 && u <= 1.0;
}


void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.n) return;
	uint info = INFO[i];
	uint kind = kind_of(info);
	if (kind == KIND_NONE) return;
	vec2 xi = X[i] + STAB[i];
	vec2 dxi = D_IN[i];
	vec2 pi = xi + dxi;
	float ri = RAD[i];
	vec4 mi = MAT[2u * mat_of(info)];
	float wi = particle_w(i, info, ri);
	Acc a = Acc(vec2(0.0), 0.0, 0.0);
	float max_pen = 0.0;

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
				vec2 dxj = D_IN[j];
				vec2 xj = X[j] + STAB[j];
				vec2 dv = (xi - xj) + (dxi - dxj);
				float rj = RAD[j];
				float d0 = ri + rj;
				float d2 = dot(dv, dv);
				if (d2 >= d0 * d0) continue;
				uint infoj = INFO[j];
				if (kind_of(infoj) == KIND_SPARK || kind == KIND_SPARK) continue;
				if (same_unit(i, j, kind, kind_of(infoj))) continue;
				float dist = sqrt(d2);
				vec2 n = dist > 1e-9 * pc.r ? dv / dist : vec2(0.0, i < j ? 1.0 : -1.0);
				float pen = d0 - dist;
				vec4 mj = MAT[2u * mat_of(infoj)];
				// Shock propagation: the lower particle acts heavier.
				float b = exp(pc.stack_k * dv.y / pc.r);
				float wib = wi * b;
				float s_i = wib / (wib + particle_w(j, infoj, rj));
				acc_add(a, s_i * (n * pen + friction(n, pen, dxi - dxj, 0.5 * (mi.x + mj.x), 0.5 * (mi.y + mj.y))));
				max_pen = max(max_pen, pen / min(ri, rj));
			}
		}
	}

	if (kind == KIND_BONDED) {
		vec4 mb = MAT[2u * mat_of(info) + 1u];
		float alpha = mb.x / (pc.h * pc.h);
		bool laser = any(notEqual(pc.laser_a, pc.laser_b));
		for (uint k = 0u; k < MAX_BONDS; k++) {
			uvec2 bd = BONDS[i * MAX_BONDS + k];
			if (bd.x == 0u || (bd.x & 0x80000000u) != 0u) continue;
			uint j = bd.x - 1u;
			float rest = uintBitsToFloat(bd.y);
			vec2 dv = (xi - X[j] - STAB[j]) + (dxi - D_IN[j]);
			float dist = length(dv);
			float C = dist - rest;
			bool cut = laser && segments_cross(pi, pi - dv, pc.laser_a, pc.laser_b);
			// Partner burnt, sunk or in another fragment (laser split): bond gone.
			bool gone = kind_of(INFO[j]) != KIND_BONDED || BODY_OF[j] != BODY_OF[i];
			if (abs(C) > mb.y * rest || cut || gone) {
				BONDS[i * MAX_BONDS + k].x = bd.x | 0x80000000u;
				atomicAdd(STATS[ST_BROKEN], 1u);
				continue;
			}
			if (dist < 1e-12) continue;
			float wj = particle_w(j, INFO[j], RAD[j]);
			acc_add(a, (-C * wi / (wi + wj + alpha)) * (dv / dist));
		}
	}

	// Stage 2: immovable/kinematic surfaces see the displacement after particle
	// and bond corrections, so loads transmitted through bonds/contacts within
	// this pass are subject to static friction (and never push through walls).
	vec2 d1 = dxi + pc.omega * acc_total(a);
	Surf su = Surf(xi + d1, d1, kind == KIND_RIGID, vec4(0.0));
	if (kind != KIND_SPARK) collider_contacts(pc.t_sub, false, ri, mi, su);
	world_walls(ri, mi, su);

	if ((pc.flags & FLAG_LAST) != 0u) atomic_max_f(ST_MAX_PEN, max_pen);
	D_OUT[i] = su.d;
	if (kind == KIND_RIGID) FRIC[i] = su.fr;
}
